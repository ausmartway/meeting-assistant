import Foundation

/// Decides whether an OCR'd on-screen label is confidently a person's name, or a
/// room/device endpoint name (or anything ambiguous). Per the design decision to
/// *default to voiceprints whenever unsure*, this returns `true` ONLY when the name
/// positively looks like a person AND shows no room/device signal — everything else
/// is `false`, so the caller falls back to voice-fingerprint identification.
/// Pure and unit-tested; best-effort and tunable.
public enum HumanNameClassifier {

    /// Distinctive room/meeting words — matched anywhere in the (lowercased) name.
    private static let roomSubstrings = [
        "room", "conference", "huddle", "boardroom", "meeting",
        "会议室", "會議室", "会议", "會議", "室",
    ]

    /// Device/brand/ambiguous words — matched as whole tokens only, so a human name
    /// that merely contains these letters isn't rejected.
    private static let deviceTokens: Set<String> = [
        "poly", "logitech", "cisco", "webex", "owl", "neat", "crestron",
        "tap", "rally", "studio", "lab", "mtr", "board", "office",
    ]

    public static func isHumanName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        // --- Non-human signals: any one means "not confidently human" ---
        for kw in roomSubstrings where lower.contains(kw) { return false }
        if trimmed.contains(where: { $0.isNumber }) { return false }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count > 3 { return false }
        for t in tokens {
            if deviceTokens.contains(t.lowercased()) { return false }
            let letters = t.filter { $0.isLetter }
            if letters.count >= 3, letters == letters.uppercased(),
                letters != letters.lowercased()
            {
                return false  // ALL-CAPS device id (e.g. "IBM", "MTR")
            }
        }

        // --- Positive human shape required for a confident "true" ---
        if tokens.count == 1, isCJK(tokens[0]) {
            return tokens[0].count >= 2 && tokens[0].count <= 4
        }
        for t in tokens {
            guard let first = t.first, first.isUppercase, t.allSatisfy({ $0.isLetter }) else {
                return false
            }
        }
        return true
    }

    /// All scalars are CJK ideographs (so a short CJK name is recognized as human).
    private static func isCJK(_ s: String) -> Bool {
        !s.isEmpty
            && s.unicodeScalars.allSatisfy {
                (0x4E00...0x9FFF).contains($0.value)  // CJK Unified Ideographs
                    || (0x3400...0x4DBF).contains($0.value)  // Extension A
            }
    }
}
