import Foundation

/// Whisper models tend to emit spurious output over silence or background noise:
/// non-speech tags like `[MUSIC]`, `(silence)`, and stock phrases such as
/// "Thanks for watching!". This filter removes those segments so they never reach
/// the transcript. Kept pure and table-driven so it is easy to extend and test.
public enum HallucinationFilter {

    /// Lowercased phrases that whisper commonly hallucinates on silence.
    private static let stockPhrases: Set<String> = [
        "thanks for watching",
        "thanks for watching!",
        "thank you for watching",
        "please subscribe",
        "you",
        "bye",
    ]

    /// Return only the segments that look like genuine speech.
    public static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { !isHallucination($0.text) }
    }

    /// True if the text is empty, a bracketed/parenthesized non-speech tag, or a
    /// known stock hallucination phrase.
    static func isHallucination(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // Entirely wrapped in [...] or (...) → a non-speech annotation, not speech.
        if isFullyWrapped(trimmed, open: "[", close: "]") { return true }
        if isFullyWrapped(trimmed, open: "(", close: ")") { return true }

        // Known stock phrases, compared case-insensitively and without trailing
        // punctuation noise.
        let normalized = trimmed.lowercased()
        if stockPhrases.contains(normalized) { return true }
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if stockPhrases.contains(stripped) { return true }

        return false
    }

    private static func isFullyWrapped(_ s: String, open: Character, close: Character) -> Bool {
        guard s.first == open, s.last == close, s.count >= 2 else { return false }
        // Ensure the brackets actually wrap the whole string (no closing bracket
        // until the end), so "[note] real speech" is NOT treated as a tag.
        let interior = s.dropFirst().dropLast()
        return !interior.contains(close)
    }
}
