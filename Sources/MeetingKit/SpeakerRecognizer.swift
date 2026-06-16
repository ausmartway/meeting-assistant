import Foundation

/// Maps each diarized cluster id to a display label by matching its voiceprint
/// against the known-speaker library. Confident matches (cosine distance ≤
/// `threshold`) get the known speaker's name; everyone else becomes an anonymous
/// "Speaker N" numbered by order of first appearance. Pure and unit-tested.
public enum SpeakerRecognizer {

    /// Conservative default: only label a cluster with a known name when the
    /// voiceprint is clearly close, so we don't put the wrong name on someone.
    public static let defaultThreshold: Float = 0.45

    /// Returns clusterID → display label ("Me", "Sam", "Speaker 2", …).
    public static func resolve(
        outcome: DiarizationOutcome,
        knownSpeakers: [KnownSpeaker],
        threshold: Float = defaultThreshold
    ) -> [String: String] {
        var labels: [String: String] = [:]
        var nextAnon = 2
        // Order of first appearance across the spans (stable, deterministic).
        var seen = Set<String>()
        var clustersInOrder: [String] = []
        for span in outcome.spans where !seen.contains(span.speakerID) {
            seen.insert(span.speakerID)
            clustersInOrder.append(span.speakerID)
        }
        for cluster in clustersInOrder {
            let embedding = outcome.embeddings[cluster] ?? []
            if let name = bestMatch(embedding, knownSpeakers, threshold) {
                labels[cluster] = name
            } else {
                labels[cluster] = "Speaker \(nextAnon)"
                nextAnon += 1
            }
        }
        return labels
    }

    /// The name of the nearest known speaker within `threshold`, or nil.
    private static func bestMatch(
        _ embedding: [Float], _ known: [KnownSpeaker], _ threshold: Float
    ) -> String? {
        var best: (name: String, distance: Float)? = nil
        for speaker in known {
            let distance = VoiceMatch.cosineDistance(embedding, speaker.embedding)
            if best == nil || distance < best!.distance {
                best = (speaker.name, distance)
            }
        }
        guard let best, best.distance <= threshold else { return nil }
        return best.name
    }
}
