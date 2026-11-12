import Combine
import Foundation
import UIKit

/// Ties Spotify to the watch: polls the current song every few seconds,
/// sends changes to the watch face, and turns the watch's button messages
/// (PP play/pause, NX next, PV previous, ? resend) into Spotify calls.
@MainActor
final class AppModel: ObservableObject {
    let spotify = Spotify()
    let watch = WatchLink()
    private let keepAlive = KeepAlive()
    private let notifier = ResumeNotifier()

    @Published var clientID: String { didSet { spotify.clientID = clientID } }
    @Published private(set) var signedIn: Bool
    @Published private(set) var now: NowPlaying?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCommand: String?
    /// Newest first: watch commands, Spotify replies and errors
    @Published private(set) var activity: [String] = []
    @Published var keepRunning: Bool {
        didSet {
            UserDefaults.standard.set(keepRunning, forKey: "keepRunning")
            if keepRunning { keepAlive.start() } else { keepAlive.stop() }
        }
    }

    static let pollSeconds: TimeInterval = 3
    /// A silent pause turns into a real pause after this long, to save power
    static let silentPauseLimit: TimeInterval = 20 * 60

    /// A "pause" done by muting Spotify, so it keeps running and A can
    /// resume it even after iOS would have put a paused Spotify to sleep.
    /// Saved, so a relaunch can still restore the volume.
    struct SilentPause: Codable {
        var volume: Int
        var trackURI: String
        var contextURI: String?
        var positionMs: Int
        var text: String
        var since: Date
    }

    private var silent: SilentPause? {
        didSet {
            UserDefaults.standard.set(silent.flatMap { try? JSONEncoder().encode($0) }, forKey: "silentPause")
        }
    }

    /// Set once Spotify refuses a volume change on this phone, so silent
    /// pause isn't tried again
    private var volumeBlocked: Bool {
        get { UserDefaults.standard.bool(forKey: "volumeBlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "volumeBlocked") }
    }

    /// What the watch was last sent, so only changes go out
    private var sentText: String?
    private var sentPlaying: Bool?
    private var timer: Timer?
    private var polling = false
    private var watchSub: AnyCancellable?

    init() {
        clientID = spotify.clientID
        signedIn = spotify.isSignedIn
        keepRunning = UserDefaults.standard.object(forKey: "keepRunning") as? Bool ?? true
        silent = UserDefaults.standard.data(forKey: "silentPause")
            .flatMap { try? JSONDecoder().decode(SilentPause.self, from: $0) }

        // Re-publish the watch's changes so the UI updates
        watchSub = watch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        watch.onReceive = { [weak self] msg in Task { @MainActor in await self?.handle(msg) } }
        watch.onReady = { [weak self] in Task { @MainActor in self?.resendAll() } }
        notifier.onTap = { [weak self] in Task { @MainActor in await self?.resumeAfterTap() } }

        if keepRunning { keepAlive.start() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        activity.insert("\(Self.clock.string(from: Date()))  \(message)", at: 0)
        if activity.count > 20 { activity.removeLast() }
    }

    // MARK: Spotify account

    func signIn() async {
        do {
            try await spotify.signIn()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        signedIn = spotify.isSignedIn
        await poll()
    }

    func signOut() {
        spotify.signOut()
        signedIn = false
        now = nil
        sync()
    }

    // MARK: Polling

    func poll() async {
        guard spotify.isSignedIn, !polling else { return }
        polling = true
        defer { polling = false }
        do {
            let fetched = try await spotify.nowPlaying()
            if let pause = silent {
                await checkSilentPause(pause)
            }
            if let pause = silent {
                // Spotify is really still playing, muted: show it as paused
                now = NowPlaying(text: pause.text, isPlaying: false)
            } else if let playing = fetched {
                now = playing
            } else if let last = now {
                // Spotify drops a paused session after a while: keep the
                // last song on the watch, shown as paused, so A can resume it
                now = NowPlaying(text: last.text, isPlaying: false)
            }
            lastError = nil
        } catch {
            let message = error.localizedDescription
            if message != lastError { log("Poll error: \(message)") }
            lastError = message
        }
        signedIn = spotify.isSignedIn
        sync()
    }

    private func pollSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await poll()
        }
    }

    // MARK: Watch

    /// Sends whatever changed since the last send.
    private func sync() {
        guard watch.connected else { return }
        let text = now?.text ?? ""
        let playing = now?.isPlaying ?? false
        if text != sentText {
            if text.isEmpty {
                watch.send("X")
            } else {
                WatchText.songMessages(text).forEach { watch.send($0) }
            }
            sentText = text
            sentPlaying = nil   // "X" resets the face's play state; resend it
        }
        if !text.isEmpty && playing != sentPlaying {
            watch.send(playing ? "P1" : "P0")
            sentPlaying = playing
        }
    }

    private func resendAll() {
        sentText = nil
        sentPlaying = nil
        sync()
    }

    private func handle(_ raw: String) async {
        let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastCommand = msg
        log("Watch: \(msg)")
        do {
            switch msg {
            case "?":
                resendAll()
                return
            case "PP":
                let wasPlaying = now?.isPlaying ?? false
                // Show the change on the watch straight away
                if now != nil { now?.isPlaying = !wasPlaying; sync() }
                if wasPlaying { try await pauseNow() } else { try await resumeNow() }
            case "NX", "PV":
                if msg == "NX" { try await spotify.next() } else { try await spotify.previous() }
                log(msg == "NX" ? "Spotify: next" : "Spotify: previous")
                // Skipping while silently paused means "play this": unmute
                if let pause = silent {
                    try await spotify.setVolume(pause.volume)
                    silent = nil
                    log("Silent pause ended, volume back to \(pause.volume)%")
                }
            default:
                return
            }
        } catch {
            log("Error: \(error.localizedDescription)")
        }
        pollSoon()
    }

    // MARK: Pause and resume

    /// Mutes instead of pausing when Spotify allows it, so Spotify stays
    /// awake; otherwise a real pause.
    private func pauseNow() async throws {
        if !volumeBlocked, let p = spotify.playback, p.isPlaying, p.volume > 0, let track = p.trackURI {
            let pause = SilentPause(volume: p.volume, trackURI: track, contextURI: p.contextURI,
                                    positionMs: p.positionNow, text: now?.text ?? "", since: Date())
            do {
                try await spotify.setVolume(0)
                silent = pause
                log("Silent pause: muted \(p.deviceName) (was \(p.volume)%)")
                return
            } catch {
                volumeBlocked = true
                log("Volume control refused (\(error.localizedDescription)). Using real pause from now on.")
            }
        } else if !volumeBlocked, let p = spotify.playback, !p.supportsVolume {
            volumeBlocked = true
            log("\(p.deviceName) doesn't allow volume control. Using real pause.")
        }
        try await spotify.pause()
        log("Spotify: paused")
    }

    private func resumeNow() async throws {
        if let pause = silent {
            // Back to the same song and spot, then unmute
            if spotify.playback?.trackURI == pause.trackURI {
                try await spotify.seek(pause.positionMs)
            } else {
                try await spotify.play(track: pause.trackURI, context: pause.contextURI, at: pause.positionMs)
            }
            try await spotify.setVolume(pause.volume)
            silent = nil
            log("Silent pause ended: back to \(pause.positionMs / 1000)s, volume \(pause.volume)%")
            return
        }
        do {
            let result = try await spotify.play()
            log(result)
            notifier.clear()
        } catch SpotifyError.noDevice {
            log("Spotify is asleep: sent PHOnE to the watch and a notification")
            watch.send("M PHOnE")
            notifier.post()
            now?.isPlaying = false
            sync()
        }
    }

    /// Ends a silent pause that the user took over or that ran too long.
    private func checkSilentPause(_ pause: SilentPause) async {
        guard let p = spotify.playback else { return }
        if p.volume > 0 {
            // Volume turned up on the phone: the user resumed it there
            silent = nil
            log("Silent pause ended on the phone")
        } else if Date().timeIntervalSince(pause.since) > Self.silentPauseLimit {
            do {
                try await spotify.pause()
                try await spotify.setVolume(pause.volume)
                silent = nil
                log("Silent pause over 20 min: real pause, volume restored")
            } catch {
                log("Error ending silent pause: \(error.localizedDescription)")
            }
        }
    }

    /// The notification was tapped: open Spotify, then keep asking it to
    /// play until it has woken up and registered as a device.
    private func resumeAfterTap() async {
        log("Notification tapped: opening Spotify")
        if let url = URL(string: "spotify:") { await UIApplication.shared.open(url) }
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                let result = try await spotify.play()
                log(result)
                pollSoon()
                return
            } catch SpotifyError.noDevice {
                continue
            } catch {
                log("Error: \(error.localizedDescription)")
                return
            }
        }
        log("Spotify didn't wake up in 15 s")
    }
}
