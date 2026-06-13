import Foundation

/// Renders labeled transcript segments into a human-readable Markdown body.
/// Consecutive segments from the same speaker are merged into a single turn so
/// the transcript reads like a conversation rather than a list of fragments.
public enum TranscriptFormatter {

    /// Build the transcript body: one line per speaker turn, prefixed with a
    /// `[mm:ss]` (or `[hh:mm:ss]`) timestamp.
    public static func transcriptBody(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        var turns: [(start: TimeInterval, speaker: String, text: String)] = []
        for seg in segments {
            if var last = turns.last, last.speaker == seg.speaker {
                last.text += " " + seg.text
                turns[turns.count - 1] = last
            } else {
                turns.append((seg.start, seg.speaker, seg.text))
            }
        }

        return turns
            .map { "**[\(timestamp($0.start))] \($0.speaker):** \($0.text)" }
            .joined(separator: "\n")
    }

    /// A full meeting document: title + date header followed by the transcript.
    public static func document(meeting: Meeting, segments: [LabeledSegment]) -> String {
        let date = ISO8601DateFormatter().string(from: meeting.startDate)
        return "# \(meeting.title)\n\(date)\n\n\(transcriptBody(segments))\n"
    }

    /// Format seconds as `mm:ss`, or `hh:mm:ss` once past an hour.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
