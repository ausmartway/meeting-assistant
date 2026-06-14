import Foundation

/// Renders labeled transcript segments into a human-readable Markdown body.
/// Consecutive segments from the same speaker are merged into a single turn so
/// the transcript reads like a conversation rather than a list of fragments.
public enum TranscriptFormatter {

    /// Build the transcript body: one line per speaker turn, prefixed with a
    /// timestamp. With `baseDate` set, the timestamp is the **real wall-clock
    /// time** (`HH:mm:ss`) of when each turn was spoken (baseDate + offset);
    /// without it, an elapsed `[mm:ss]` offset.
    public static func transcriptBody(
        _ segments: [LabeledSegment],
        baseDate: Date? = nil,
        timeZone: TimeZone = .current
    ) -> String {
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
            .map { "**[\(timestamp($0.start, baseDate: baseDate, timeZone: timeZone))] \($0.speaker):** \($0.text)" }
            .joined(separator: "\n")
    }

    /// A full meeting document: title + recording time header, an optional note
    /// line, then the transcript with real wall-clock timestamps.
    public static func document(
        meeting: Meeting,
        segments: [LabeledSegment],
        baseDate: Date? = nil,
        note: String? = nil
    ) -> String {
        let start = baseDate ?? meeting.startDate
        let date = ISO8601DateFormatter().string(from: start)
        let noteLine = note.map { "\n_\($0)_\n" } ?? ""
        return "# \(meeting.title)\n\(date)\n\(noteLine)\n\(transcriptBody(segments, baseDate: start))\n"
    }

    /// Format a segment offset. With `baseDate`, returns the real clock time
    /// `HH:mm:ss`; otherwise an elapsed `mm:ss` / `hh:mm:ss` offset.
    static func timestamp(_ seconds: TimeInterval, baseDate: Date? = nil, timeZone: TimeZone = .current) -> String {
        if let baseDate {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let c = cal.dateComponents([.hour, .minute, .second], from: baseDate.addingTimeInterval(seconds))
            return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        }
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
