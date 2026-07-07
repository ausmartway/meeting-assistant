import Foundation

/// Pure mapping from parsed transcript turns to playable audio clips, so the UI
/// can play the exact moment behind a line (speaker verification, R27).
///
/// Precise path: `segments.json` pairs with turns by index (the formatter writes
/// one line per segment, in order), sanity-checked per index by speaker AND the
/// rendered timestamp. Any mismatch degrades that turn (or, on count mismatch,
/// every turn) to the fallback: derive the offset from the turn's wall-clock
/// stamp and guess the file from the label — best-effort by design; in-room
/// named speakers can guess wrong until the meeting is re-transcribed.
public enum TranscriptAudioLocator {

    public struct ClipLocation: Equatable, Sendable {
        public let fileName: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(fileName: String, start: TimeInterval, end: TimeInterval) {
            self.fileName = fileName
            self.start = start
            self.end = end
        }
    }

    /// End of a fallback window: the next turn's start, at most this much later.
    static let maxFallbackClip: TimeInterval = 30
    /// Fallback window for the last turn (no next turn to bound it).
    static let lastTurnClip: TimeInterval = 15

    public static func locate(
        turns: [TranscriptParser.Turn],
        segments: [LabeledSegment]?,
        recordedAt: Date,
        localUserName: String,
        micFileName: String,
        systemFileName: String,
        timeZone: TimeZone = .current
    ) -> [ClipLocation?] {
        // Fallback offsets are shared by both paths (per-turn degradation).
        let offsets = turns.map { offset(of: $0.time, recordedAt: recordedAt, timeZone: timeZone) }
        let usable = (segments?.count == turns.count) ? segments : nil

        return turns.indices.map { i in
            let guessedFile =
                turns[i].speaker == localUserName ? micFileName : systemFileName
            if let seg = usable?[i], seg.speaker == turns[i].speaker,
                TranscriptFormatter.timestamp(seg.start, baseDate: recordedAt, timeZone: timeZone)
                    == turns[i].time
            {
                let file: String
                switch seg.channel {
                case .microphone: file = micFileName
                case .system: file = systemFileName
                case nil: file = guessedFile
                }
                return ClipLocation(fileName: file, start: seg.start, end: seg.end)
            }
            // Fallback: stamp-derived window.
            guard let start = offsets[i] else { return nil }
            let end: TimeInterval
            if i + 1 < turns.count, let next = offsets[i + 1], next > start {
                end = min(next, start + maxFallbackClip)
            } else {
                end = start + lastTurnClip
            }
            return ClipLocation(fileName: guessedFile, start: start, end: end)
        }
    }

    /// Meeting-relative offset of a rendered stamp. "HH:mm:ss" is wall-clock
    /// (the formatter always renders with baseDate): offset = stamp − recordedAt's
    /// clock time, +24 h on midnight wrap. "MM:SS" is already an offset.
    static func offset(of stamp: String, recordedAt: Date, timeZone: TimeZone) -> TimeInterval? {
        let parts = stamp.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), !parts.isEmpty else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2:  // "MM:SS" — meeting-relative (legacy relative rendering)
            return TimeInterval(values[0] * 60 + values[1])
        case 3:  // "HH:mm:ss" — wall clock
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let base = cal.dateComponents([.hour, .minute, .second], from: recordedAt)
            let stampSeconds = values[0] * 3600 + values[1] * 60 + values[2]
            let baseSeconds =
                (base.hour ?? 0) * 3600 + (base.minute ?? 0) * 60 + (base.second ?? 0)
            var offset = stampSeconds - baseSeconds
            if offset < 0 { offset += 24 * 3600 }  // crossed midnight
            return TimeInterval(offset)
        default:
            return nil
        }
    }
}
