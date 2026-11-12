import Combine
import Foundation

/// Ties Spotify to the watch: polls the current song every few seconds,
/// sends changes to the watch face, and turns the watch's button messages
/// (PP play/pause, NX next, PV previous, ? resend) into Spotify calls.
@MainActor
final class AppModel: ObservableObject {
    let spotify = Spotify()
    let watch = WatchLink()
    private let keepAlive = KeepAlive()

    @Published var clientID: String { didSet { spotify.clientID = clientID } }
    @Published private(set) var signedIn: Bool
    @Published private(set) var now: NowPlaying?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCommand: String?
    @Published var keepRunning: Bool {
        didSet {
            UserDefaults.standard.set(keepRunning, forKey: "keepRunning")
            if keepRunning { keepAlive.start() } else { keepAlive.stop() }
        }
    }

    static let pollSeconds: TimeInterval = 3

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

        // Re-publish the watch's changes so the UI updates
        watchSub = watch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        watch.onReceive = { [weak self] msg in Task { @MainActor in await self?.handle(msg) } }
        watch.onReady = { [weak self] in Task { @MainActor in self?.resendAll() } }

        if keepRunning { keepAlive.start() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
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
            now = try await spotify.nowPlaying()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
        do {
            switch msg {
            case "?":
                resendAll()
                return
            case "PP":
                let wasPlaying = now?.isPlaying ?? false
                // Show the change on the watch straight away
                if now != nil { now?.isPlaying = !wasPlaying; sync() }
                if wasPlaying { try await spotify.pause() } else { try await spotify.play() }
            case "NX":
                try await spotify.next()
            case "PV":
                try await spotify.previous()
            default:
                return
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        pollSoon()
    }
}
