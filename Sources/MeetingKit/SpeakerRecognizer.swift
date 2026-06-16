import Foundation

/// Maps each diarized cluster id to a display label by matching its voiceprint
/// against the known-speaker library. Confident matches (cosine distance ≤
/// `threshold`) get the known speaker's name; everyone else becomes an anonymous
/// "Speaker N" numbered by order of first appearance. Pure and unit-tested.
public enum SpeakerRecognizer {

    /// Conservative default: only label a cluster with a known name when the
    /// voiceprint is clearly close, so we don't put the wrong name on someone.
    public static let defaultThreshold: Float = 0.40

    /// Returns clusterID → display label ("Me", "Sam", "Speaker 2", …).
    public static func resolve(
        outcome: DiarizationOutcome,
        knownSpeakers: [KnownSpeaker],
        threshold: Float = defaultThreshold
    ) -> [String: String] {
        // Order of first appearance across the spans (stable, deterministic).
        var seen = Set<String>()
        var clustersInOrder: [String] = []
        for span in outcome.spans where !seen.contains(span.speakerID) {
            seen.insert(span.speakerID)
            clustersInOrder.append(span.speakerID)
        }

        // Pass 1: each cluster's nearest known speaker within threshold (or nil).
        var match: [String: (name: String, distance: Float)] = [:]
        for cluster in clustersInOrder {
            if let m = bestMatch(outcome.embeddings[cluster] ?? [], knownSpeakers, threshold) {
                match[cluster] = m
            }
        }

        // A known name must map to at most ONE cluster — the closest. Other
        // clusters that matched the same name fall back to anonymous, so we never
        // print two "Sam" turns (which would also confuse the rename/relearn flow).
        var winnerForName: [String: String] = [:]   // name → winning cluster id
        for (cluster, m) in match {
            if let current = winnerForName[m.name], let cur = match[current], cur.distance <= m.distance {
                continue
            }
            winnerForName[m.name] = cluster
        }

        // Pass 2: assign labels. Known matches keep their name; everyone else is
        // numbered "Speaker N" by first appearance, starting at 2. "Speaker 1" is
        // reserved by convention for the local user ("Me"), kept stable across
        // meetings even when a given meeting doesn't resolve a "Me" cluster — so the
        // same person doesn't get a different number from one meeting to the next.
        var nextAnon = 2
        var labels: [String: String] = [:]
        for cluster in clustersInOrder {
            if let m = match[cluster], winnerForName[m.name] == cluster {
                labels[cluster] = m.name
            } else {
                labels[cluster] = "Speaker \(nextAnon)"
                nextAnon += 1
            }
        }
        return labels
    }

    /// The nearest known speaker within `threshold` (name + distance), or nil.
    private static func bestMatch(
        _ embedding: [Float], _ known: [KnownSpeaker], _ threshold: Float
    ) -> (name: String, distance: Float)? {
        var best: (name: String, distance: Float)? = nil
        for speaker in known {
            let distance = VoiceMatch.cosineDistance(embedding, speaker.embedding)
            if best == nil || distance < best!.distance {
                best = (speaker.name, distance)
            }
        }
        guard let best, best.distance <= threshold else { return nil }
        return best
    }
}
