import Foundation

/// Pure rewrite of a rendered transcript's speaker labels: replace every
/// occurrence of one speaker's label with a new name, without touching body text
/// that merely happens to contain the name. Used when the user renames a speaker.
///
/// Targets the exact line shape `TranscriptFormatter` emits:
/// `**[HH:MM:SS] <speaker>:** <text>`. The speaker label is the token between the
/// closing `] ` of the timestamp and the `:**` that separates label from text, so
/// we rewrite only that token — never `old` as it appears inside `<text>`.
public enum TranscriptRelabeler {
    private static let prefix = "**["
    private static let labelOpen = "] "
    private static let labelClose = ":**"

    public static func rename(in transcript: String, from old: String, to new: String) -> String {
        guard old != new else { return transcript }

        // Preserve the original line structure (including a trailing newline).
        let lines = transcript.components(separatedBy: "\n")
        let rewritten = lines.map { rewriteLine($0, from: old, to: new) }
        return rewritten.joined(separator: "\n")
    }

    /// Rewrite a single line iff its speaker-label token equals `old`.
    private static func rewriteLine(_ line: String, from old: String, to new: String) -> String {
        guard line.hasPrefix(prefix),
              let labelOpenRange = line.range(of: labelOpen),
              let labelCloseRange = line.range(of: labelClose, range: labelOpenRange.upperBound..<line.endIndex)
        else { return line }

        let label = String(line[labelOpenRange.upperBound..<labelCloseRange.lowerBound])
        guard label == old else { return line }

        return line.replacingCharacters(
            in: labelOpenRange.upperBound..<labelCloseRange.lowerBound,
            with: new
        )
    }
}
