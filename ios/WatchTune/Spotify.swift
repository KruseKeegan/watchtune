import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct NowPlaying: Equatable {
    var text: String      // "Title - Artist", already cleaned for the watch
    var isPlaying: Bool
}

enum SpotifyError: LocalizedError {
    case noClientID, notSignedIn, noDevice, signInFailed(String), http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noClientID: return "Enter your Spotify Client ID first."
        case .notSignedIn: return "Sign in to Spotify first."
        case .noDevice: return "Spotify lists no devices: the Spotify app is asleep. Open it on the phone."
        case .signInFailed(let m): return "Spotify sign-in failed: \(m)"
        case .http(let code, let body): return "Spotify error \(code): \(body.prefix(160))"
        }
    }
}

/// Spotify sign-in (Authorization Code with PKCE, no client secret) and the
/// few Web API calls WatchTune needs. Runs on the main thread.
@MainActor
final class Spotify {
    /// Must match the Redirect URI registered in the Spotify dashboard
    /// exactly. The page bounces the code to watchtune://callback.
    static let redirectURI = "https://krusekeegan.github.io/watchtune/callback/"
    static let callbackScheme = "watchtune"
    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"

    private let defaults = UserDefaults.standard
    private var session: ASWebAuthenticationSession?
    private var anchor: AnchorProvider?
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    /// No more requests until this time, after a 429 rate limit.
    private var backoffUntil = Date.distantPast

    var clientID: String {
        get { defaults.string(forKey: "spotifyClientID") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotifyClientID") }
    }

    private var refreshToken: String? {
        get { defaults.string(forKey: "spotifyRefreshToken") }
        set { defaults.set(newValue, forKey: "spotifyRefreshToken") }
    }

    var isSignedIn: Bool { refreshToken != nil }

    func signOut() {
        refreshToken = nil
        accessToken = nil
        accessExpiry = .distantPast
    }

    // MARK: Sign-in

    func signIn() async throws {
        guard !clientID.isEmpty else { throw SpotifyError.noClientID }
        let verifier = Self.randomString(64)
        let state = Self.randomString(16)
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url = url { cont.resume(returning: url) }
                else { cont.resume(throwing: SpotifyError.signInFailed(error?.localizedDescription ?? "cancelled")) }
            }
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            anchor = AnchorProvider(window: window)
            s.presentationContextProvider = anchor
            session = s
            if !s.start() { cont.resume(throwing: SpotifyError.signInFailed("couldn't open the sign-in page")) }
        }
        session = nil
        anchor = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let err = item("error") { throw SpotifyError.signInFailed(err) }
        guard item("state") == state, let code = item("code") else {
            throw SpotifyError.signInFailed("unexpected reply")
        }
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    private func tokenRequest(_ params: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            if status == 400 || status == 401 { signOut() }  // refresh token revoked
            throw SpotifyError.http(status, String(decoding: data, as: UTF8.self))
        }
        accessToken = token
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        accessExpiry = Date().addingTimeInterval(expiresIn)
        // A refresh may or may not hand out a new refresh token
        if let refresh = json["refresh_token"] as? String { refreshToken = refresh }
    }

    private func validToken() async throws -> String {
        if let t = accessToken, accessExpiry > Date().addingTimeInterval(60) { return t }
        guard let refresh = refreshToken else { throw SpotifyError.notSignedIn }
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        return accessToken!
    }

    // MARK: Web API

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil, retry: Bool = true) async throws -> (Data, Int) {
        if Date() < backoffUntil { throw SpotifyError.http(429, "rate limited, waiting") }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            req.httpBody = Data()
            req.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 && retry {
            accessToken = nil
            return try await call(method, path, body: body, retry: false)
        }
        if status == 429 {
            let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            backoffUntil = Date().addingTimeInterval(wait)
        }
        guard (200..<300).contains(status) else {
            throw SpotifyError.http(status, String(decoding: data, as: UTF8.self))
        }
        return (data, status)
    }

    /// Device id of the last playback Spotify reported, for resuming when
    /// no device is active any more.
    private(set) var lastDeviceID: String? {
        get { defaults.string(forKey: "spotifyLastDevice") }
        set { defaults.set(newValue, forKey: "spotifyLastDevice") }
    }

    /// Details of the last playback Spotify reported, for silent pause and
    /// resume. nil when Spotify has no active playback.
    private(set) var playback: Playback?

    struct Playback {
        var deviceID: String?
        var deviceName: String
        var supportsVolume: Bool
        var volume: Int
        var trackURI: String?
        var contextURI: String?
        var progressMs: Int
        var isPlaying: Bool
        var fetchedAt: Date

        /// Where the song is now, allowing for time since the poll
        var positionNow: Int {
            isPlaying ? progressMs + Int(Date().timeIntervalSince(fetchedAt) * 1000) : progressMs
        }
    }

    /// The current song, or nil if Spotify has no active playback (e.g. the
    /// Spotify app went to sleep after a while paused).
    func nowPlaying() async throws -> NowPlaying? {
        let (data, status) = try await call("GET", "/me/player?additional_types=episode")
        guard status != 204, !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            playback = nil
            return nil
        }
        let device = json["device"] as? [String: Any] ?? [:]
        if let id = device["id"] as? String { lastDeviceID = id }
        let playing = (json["is_playing"] as? Bool) ?? false
        let item = json["item"] as? [String: Any]
        playback = Playback(
            deviceID: device["id"] as? String,
            deviceName: device["name"] as? String ?? "?",
            supportsVolume: device["supports_volume"] as? Bool ?? false,
            volume: device["volume_percent"] as? Int ?? 0,
            trackURI: item?["uri"] as? String,
            contextURI: (json["context"] as? [String: Any])?["uri"] as? String,
            progressMs: json["progress_ms"] as? Int ?? 0,
            isPlaying: playing,
            fetchedAt: Date())
        guard let item = item, let name = item["name"] as? String else {
            // Ads and some local files have no item
            return (json["currently_playing_type"] as? String) == "ad"
                ? NowPlaying(text: "Ad", isPlaying: playing) : nil
        }
        var by = ""
        if let artists = item["artists"] as? [[String: Any]] {
            by = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
        } else if let show = item["show"] as? [String: Any] {
            by = (show["name"] as? String) ?? ""
        }
        let full = by.isEmpty ? name : "\(name) - \(by)"
        return NowPlaying(text: WatchText.clean(full), isPlaying: playing)
    }

    /// Resumes playback and says how. If no device is active (Spotify
    /// answers 404), it moves playback to the last device used, or a phone,
    /// or any device Spotify lists. Throws `noDevice` if there's none.
    func play() async throws -> String {
        do {
            _ = try await call("PUT", "/me/player/play")
            return "Spotify: resumed"
        } catch SpotifyError.http(404, _) {
            let (data, _) = try await call("GET", "/me/player/devices")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let devices = (json?["devices"] as? [[String: Any]]) ?? []
            let names = devices.map { "\($0["name"] as? String ?? "?") (\($0["type"] as? String ?? "?"))" }
            let pick = devices.first { ($0["id"] as? String) == lastDeviceID }
                ?? devices.first { ($0["type"] as? String) == "Smartphone" }
                ?? devices.first
            guard let id = pick?["id"] as? String else { throw SpotifyError.noDevice }
            _ = try await call("PUT", "/me/player", body: ["device_ids": [id], "play": true])
            return "Spotify: no active device. Devices: \(names.joined(separator: ", ")). Moved playback to \(pick?["name"] as? String ?? id)"
        }
    }

    func setVolume(_ percent: Int) async throws {
        _ = try await call("PUT", "/me/player/volume?volume_percent=\(max(0, min(100, percent)))")
    }

    func seek(_ ms: Int) async throws {
        _ = try await call("PUT", "/me/player/seek?position_ms=\(max(0, ms))")
    }

    /// Plays `trackURI` from `positionMs`, inside its playlist/album when
    /// there is one so the queue carries on after it.
    func play(track trackURI: String, context contextURI: String?, at positionMs: Int) async throws {
        if let ctx = contextURI {
            do {
                _ = try await call("PUT", "/me/player/play", body: [
                    "context_uri": ctx, "offset": ["uri": trackURI], "position_ms": positionMs])
                return
            } catch SpotifyError.http(let code, _) where code == 400 || code == 404 {
                // Some contexts (e.g. an artist) don't take an offset
            }
        }
        _ = try await call("PUT", "/me/player/play", body: ["uris": [trackURI], "position_ms": positionMs])
    }

    func pause() async throws { _ = try await call("PUT", "/me/player/pause") }
    func next() async throws { _ = try await call("POST", "/me/player/next") }
    func previous() async throws { _ = try await call("POST", "/me/player/previous") }

    // MARK: Helpers

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var gen = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars[Int(gen.next() % UInt64(chars.count))] })
    }

    private static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }
}

/// Tells the sign-in sheet which window to show over.
final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow?
    init(window: UIWindow?) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? ASPresentationAnchor()
    }
}
