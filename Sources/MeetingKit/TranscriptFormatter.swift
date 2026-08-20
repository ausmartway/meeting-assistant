import Foundation

/// Renders labeled transcript segments into a human-readable Markdown body.
/// Consecutive segments from the same speaker are merged into a single turn so
/// the transcript reads like a conversation rather than a list of fragments.
public enum TranscriptFormatter {

    /// Build the transcript body: one line per speaker turn, prefixed with a
    /// timestamp. With `baseDate` set, the timestamp is the **real wall-clock
    /// time** (`HH:mm:ss`) of when each turn was spoken (baseDate + offset);
    /// without it, an elapsed `[mm:ss]` offset.
    ///
    /// `slides` (R28) are written in as Markdown image lines, each after the last turn
    /// that started before it — so the reader meets a slide where it appeared in the
    /// conversation. Real Markdown, so an exported transcript renders the images in any
    /// viewer that has the `slides/` folder beside it, and degrades to the alt text
    /// where it doesn't.
    public static func transcriptBody(
        _ segments: [LabeledSegment],
        baseDate: Date? = nil,
        timeZone: TimeZone = .current,
        slides: [SlideKeyframe] = []
    ) -> String {
        guard !segments.isEmpty || !slides.isEmpty else { return "" }

        var turns: [(start: TimeInterval, speaker: String, text: String)] = []
        for seg in segments {
            if var last = turns.last, last.speaker == seg.speaker {
                last.text += " " + seg.text
                turns[turns.count - 1] = last
            } else {
                turns.append((seg.start, seg.speaker, seg.text))
            }
        }

        func slideLine(_ slide: SlideKeyframe) -> String {
            let stamp = timestamp(slide.timestamp, baseDate: baseDate, timeZone: timeZone)
            return "![Shared screen \(stamp)](\(slide.file))"
        }

        let ordered = slides.sorted { $0.timestamp < $1.timestamp }
        var lines: [String] = []
        var pending = ordered[...]

        for turn in turns {
            // Slides that appeared before this turn started belong above it.
            while let next = pending.first, next.timestamp < turn.start {
                lines.append(slideLine(next))
                pending = pending.dropFirst()
            }
            lines.append(
                "**[\(timestamp(turn.start, baseDate: baseDate, timeZone: timeZone))] \(turn.speaker):** \(turn.text)"
            )
        }
        // Anything left appeared after the last turn began.
        for slide in pending { lines.append(slideLine(slide)) }

        return lines.joined(separator: "\n")
    }

    /// A full meeting document: title + recording time header, an optional note
    /// line, then the transcript with real wall-clock timestamps.
    public static func document(
        meeting: Meeting,
        segments: [LabeledSegment],
        baseDate: Date? = nil,
        note: String? = nil,
        slides: [SlideKeyframe] = []
    ) -> String {
        let start = baseDate ?? meeting.startDate
        let date = ISO8601DateFormatter().string(from: start)
        let noteLine = note.map { "\n_\($0)_\n" } ?? ""
        return
            "# \(meeting.title)\n\(date)\n\(noteLine)\n\(transcriptBody(segments, baseDate: start, slides: slides))\n"
    }

    /// Format a segment offset. With `baseDate`, returns the real clock time
    /// `HH:mm:ss`; otherwise an elapsed `mm:ss` / `hh:mm:ss` offset.
    static func timestamp(
        _ seconds: TimeInterval, baseDate: Date? = nil, timeZone: TimeZone = .current
    ) -> String {
        if let baseDate {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let c = cal.dateComponents(
                [.hour, .minute, .second], from: baseDate.addingTimeInterval(seconds))
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
