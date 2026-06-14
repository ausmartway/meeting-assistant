import Foundation

/// Strips WhisperKit's special / timestamp tokens (`<|startoftranscript|>`,
/// `<|zh|>`, `<|transcribe|>`, `<|12.34|>`, …) out of a segment's raw text so the
/// transcript reads naturally. These tokens otherwise appear inline in the
/// rendered transcript.
public enum WhisperTextCleaner {

    public static func clean(_ text: String) -> String {
        // Remove any <|...|> token (content has no '|' or '>').
        let noTokens = text.replacingOccurrences(
            of: #"<\|[^|>]*\|>"#, with: " ", options: .regularExpression
        )
        // Collapse the whitespace left behind, then trim.
        let collapsed = noTokens.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
