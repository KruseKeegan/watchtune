import Foundation

/// Turns a song title into text the watch can show: printable ASCII only
/// (the 7-segment LCD has no other glyphs), single spaces, at most
/// `maxLength` characters (the watch face caps its buffer at 120).
enum WatchText {
    static let maxLength = 120

    static func clean(_ s: String) -> String {
        var t = s
        let swaps: [String: String] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
            "\u{2013}": "-", "\u{2014}": "-", "\u{2026}": "...", "&": "+",
        ]
        for (from, to) in swaps { t = t.replacingOccurrences(of: from, with: to) }
        // é -> e, ü -> u, full-width -> normal width
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        let scalars = t.unicodeScalars.map { (0x20...0x7E).contains($0.value) ? Character($0) : " " }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }

    /// Splits a song into the S/C/E writes the watch face expects, each
    /// at most 20 bytes (1 type byte + 19 text bytes).
    static func songMessages(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        repeat {
            let end = min(i + 19, chars.count)
            out.append((i == 0 ? "S" : "C") + String(chars[i..<end]))
            i = end
        } while i < chars.count
        out.append("E")
        return out
    }
}
