import Foundation

/// A minimal, FluidAudio-free view of one Parakeet token timing, so the
/// segment-building logic stays pure and unit-testable without importing the SDK.
public struct ParakeetToken: Sendable, Equatable {
    public let token: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public init(token: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Turns Parakeet's per-token timings into `[TranscriptSegment]`. Parakeet returns
/// one continuous result with token-level times (not the sentence segments Whisper
/// gives), so we group tokens into segments on sentence-ending punctuation or a
/// long pause — granular enough for `SpeakerFuser` to interleave mic/system and
/// align the on-screen speaker timeline.
public enum ParakeetSegmentBuilder {
    /// Tokens whose trimmed text ends with one of these closes the current segment.
    private static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    /// A silence gap (seconds) between adjacent tokens that also closes a segment.
    private static let pauseThreshold: TimeInterval = 1.0

    public static func segments(
        tokens: [ParakeetToken],
        channel: AudioChannel,
        fallbackText: String,
        fallbackDuration: TimeInterval
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [ParakeetToken] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.token).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: first.startTime, end: last.endTime, text: text, channel: channel
                ))
            }
            current.removeAll()
        }

        for token in tokens {
            if let prev = current.last, token.startTime - prev.endTime >= pauseThreshold {
                flush()
            }
            current.append(token)
            let trimmed = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastChar = trimmed.last, terminators.contains(lastChar) {
                flush()
            }
        }
        flush()

        // No usable tokens (e.g. timings absent) → one segment for the whole clip.
        if segments.isEmpty {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: 0, end: fallbackDuration, text: text, channel: channel
                ))
            }
        }
        return segments
    }
}
