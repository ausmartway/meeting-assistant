import Foundation

/// Pure logic that turns a diarizer's raw speaker spans into display labels and
/// resolves the label active at a given time. Kept pure and table-driven so it is
/// easy to test without any model.
public enum DiarizationLabeler {

    /// The id the diarizer uses for the enrolled local user.
    public static let meSpeakerID = "Me"

    /// Map each distinct `speakerID` to a display label: the enrolled user stays
    /// "Me"; every other speaker becomes "Speaker 2", "Speaker 3", … numbered by
    /// order of first appearance across `spans`.
    public static func displayLabels(for spans: [DiarizedSpan]) -> [String: String] {
        var labels: [String: String] = [:]
        var next = 2
        for span in spans where labels[span.speakerID] == nil {
            if span.speakerID == meSpeakerID {
                labels[span.speakerID] = "Me"
            } else {
                labels[span.speakerID] = "Speaker \(next)"
                next += 1
            }
        }
        return labels
    }

    /// The display label of the span whose `[start, end)` contains `t`, or nil if
    /// `t` falls in a gap. End is exclusive so adjacent spans don't both match.
    public static func speaker(
        at t: TimeInterval,
        spans: [DiarizedSpan],
        labels: [String: String]
    ) -> String? {
        guard let span = spans.first(where: { t >= $0.start && t < $0.end }) else { return nil }
        return labels[span.speakerID]
    }
}
