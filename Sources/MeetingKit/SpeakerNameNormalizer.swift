import Foundation

/// Pure cleaning + grouping helpers for OCR'd participant names.
///
/// `displayName` produces the label we show; `canonicalKey` produces a folded key
/// used only to group trivial variants (whitespace/case/diacritics) of the same
/// name during multi-frame voting. Both are deterministic and unit-tested.
public enum SpeakerNameNormalizer {

    /// Trailing role/parenthetical markers meeting apps append to a name.
    /// Matched case-insensitively, with either ASCII `()` or fullwidth `（）`.
    private static let roleMarkers: Set<String> = [
        "host", "co-host", "cohost", "you", "me", "guest", "organizer", "organiser",
        "主持人", "你", "我", "联席主持人", "聯席主持人", "访客", "訪客",
    ]

    /// A cleaned display name, or nil if nothing name-like remains.
    public static func displayName(_ raw: String) -> String? {
        // Strip a single trailing "(...)" / "（...）" group if its content is a role marker.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = strippingTrailingRole(s) { s = stripped }
        // Collapse internal whitespace runs to single spaces.
        let collapsed = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject empties and single characters (not a usable name).
        guard collapsed.count >= 2 else { return nil }
        return collapsed
    }

    /// Folded key for grouping variants: lowercased, diacritics-removed, whitespace removed.
    public static func canonicalKey(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.filter { !$0.isWhitespace }
    }

    /// If `s` ends in a "(role)" / "（role）" group, return `s` without it; else nil.
    private static func strippingTrailingRole(_ s: String) -> String? {
        let pairs: [(Character, Character)] = [("(", ")"), ("（", "）")]
        for (open, close) in pairs where s.hasSuffix(String(close)) {
            guard let openIdx = s.lastIndex(of: open) else { continue }
            let inside = s[s.index(after: openIdx)..<s.index(before: s.endIndex)]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if roleMarkers.contains(inside) {
                return String(s[..<openIdx]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
