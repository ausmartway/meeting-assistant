import Foundation

/// Assigns a speaker label to each transcript segment by combining two signals:
///
///  1. **Audio channel** — microphone segments are the local user ("Me") by
///     default. This "you vs. others" split is exact because the two channels are
///     recorded separately, so it never depends on fragile screen reading. When
///     mic diarization spans are supplied, mic segments are instead resolved to
///     distinct in-room speakers (the enrolled user stays "Me"), falling back to
///     "Me" outside any span.
///  2. **Active-speaker timeline** — for remote (system-audio) segments, we look
///     up who was highlighted on screen at the segment's midpoint. The active
///     speaker is assumed to hold until the next sample, so we take the most
///     recent sample at or before the midpoint.
///
/// When no name is available (no sample, or the highlight had no readable name)
/// the segment gets a generic fallback label.
public enum SpeakerFuser {

    public static func fuse(
        segments: [TranscriptSegment],
        timeline: SpeakerTimeline,
        micDiarization: [DiarizedSpan] = [],
        micLabels: [String: String] = [:],
        micLabel: String = "Me",
        unknownLabel: String = "Speaker"
    ) -> [LabeledSegment] {
        return segments.map { segment in
            let midpoint = (segment.start + segment.end) / 2
            let speaker: String
            switch segment.channel {
            case .microphone:
                // No diarization → today's behavior. Otherwise resolve the span at
                // the segment midpoint and map its cluster id through `micLabels`,
                // falling back to "Me" in gaps or for unmapped clusters.
                if micDiarization.isEmpty {
                    speaker = micLabel
                } else if let span = span(at: midpoint, in: micDiarization) {
                    speaker = micLabels[span.speakerID] ?? micLabel
                } else {
                    speaker = micLabel
                }
            case .system:
                speaker = activeSpeaker(at: midpoint, in: timeline) ?? unknownLabel
            }
            return LabeledSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speaker
            )
        }
    }

    /// The first diarization span whose `[start, end)` contains `t` (end
    /// exclusive so adjacent spans don't both match), or nil if `t` is in a gap.
    private static func span(at t: TimeInterval, in spans: [DiarizedSpan]) -> DiarizedSpan? {
        spans.first(where: { t >= $0.start && t < $0.end })
    }

    /// The on-screen active speaker's name at time `t`, or nil if unknown.
    /// `timeline.samples` is guaranteed sorted by timestamp.
    private static func activeSpeaker(at t: TimeInterval, in timeline: SpeakerTimeline) -> String? {
        let samples = timeline.samples
        guard !samples.isEmpty else { return nil }

        // Most recent sample at or before t (the speaker holds until the next sample).
        if let recent = samples.last(where: { $0.timestamp <= t }) {
            return recent.speakerName
        }
        // t precedes every sample (meeting just started) — best guess is the first.
        return samples.first?.speakerName
    }
}
