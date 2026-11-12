import AVFoundation
import Foundation

/// Keeps WatchTune running while it's in the background, so it can keep
/// checking Spotify for song changes: iOS lets an app with an active audio
/// session run, so this plays a silent loop mixed in with Spotify's audio
/// (it never interrupts or ducks it). Off when the toggle is off.
final class KeepAlive {
    private var player: AVAudioPlayer?
    private(set) var running = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(contentsOf: try Self.silenceFile())
                player?.numberOfLoops = -1
                player?.volume = 0
            }
            player?.play()
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        player?.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A phone call or Siri stops the loop: start it again afterwards.
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended, running else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    private static func silenceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate: UInt32 = 8000
        let samples = Data(count: Int(rate) * 2)
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(samples.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count))
        wav.append(samples)
        try wav.write(to: url)
        return url
    }
}
