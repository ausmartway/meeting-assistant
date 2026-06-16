import Foundation

/// Assigns a speaker label to each transcript segment by combining two signals:
///
///  1. **Audio channel** — microphone segments are always the local user. This
///     "you vs. others" split is exact because the two channels are recorded
///     separately, so it never depends on fragile screen reading.
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
        micLabel: String = "Me",
        unknownLabel: String = "Speaker"
    ) -> [LabeledSegment] {
        // Precompute diarized display labels once (empty when not diarizing).
        let micLabels = DiarizationLabeler.displayLabels(for: micDiarization)
        return segments.map { segment in
            let midpoint = (segment.start + segment.end) / 2
            let speaker: String
            switch segment.channel {
            case .microphone:
                // No diarization → today's behavior. Otherwise resolve the span at
                // the segment midpoint, falling back to "Me" in gaps.
                if micDiarization.isEmpty {
                    speaker = micLabel
                } else {
                    speaker = DiarizationLabeler.speaker(
                        at: midpoint, spans: micDiarization, labels: micLabels
                    ) ?? micLabel
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
