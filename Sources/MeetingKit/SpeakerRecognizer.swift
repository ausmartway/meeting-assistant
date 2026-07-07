import Foundation

/// Maps each diarized cluster id to a display label by matching its voiceprint
/// against the known-speaker library. Confident matches (cosine distance ≤
/// `threshold`) get the known speaker's name; everyone else becomes an anonymous
/// "Speaker N" numbered by order of first appearance. Pure and unit-tested.
public enum SpeakerRecognizer {

    /// Conservative default: only label a cluster with a known name when the
    /// voiceprint is clearly close, so we don't put the wrong name on someone.
    public static let defaultThreshold: Float = 0.40

    /// A match must beat the nearest *different* known speaker by at least this much
    /// (cosine distance) to be trusted. Without it, a noisy / over-segmented
    /// voiceprint sitting almost equidistant between two enrolled people grabs
    /// whichever name it's marginally closer to — the cause of a real mislabel where
    /// a fragment of the user's own voice (0.244 from "Larry", 0.274 from "Me") was
    /// named "Larry". A confident match clears this margin comfortably (~0.4+).
    public static let defaultMargin: Float = 0.10

    /// Minimum total speech (seconds) a cluster needs before its voiceprint is
    /// trusted — for taking a known speaker's name here, and for being *learned*
    /// into the library on rename (`MeetingSpeakerMap.learnableVoiceprint`). A
    /// few seconds of noise can embed arbitrarily close to a real person (the
    /// "Joshua Li" mislabel matched at cosine distance 0.136); no distance
    /// threshold stops that, only the amount of speech behind the centroid does.
    public static let minSpeechDuration: TimeInterval = 15

    /// Total speech per cluster, summed across its diarized spans.
    public static func speechDuration(byCluster spans: [DiarizedSpan])
        -> [String: TimeInterval]
    {
        var durations: [String: TimeInterval] = [:]
        for span in spans {
            durations[span.speakerID, default: 0] += max(0, span.end - span.start)
        }
        return durations
    }

    /// Returns clusterID → display label ("Me", "Sam", "Speaker 2", …).
    public static func resolve(
        outcome: DiarizationOutcome,
        knownSpeakers: [KnownSpeaker],
        threshold: Float = defaultThreshold,
        margin: Float = defaultMargin,
        minMatchDuration: TimeInterval = minSpeechDuration,
        startingAnon: Int = 2
    ) -> [String: String] {
        // Order of first appearance across the spans (stable, deterministic).
        var seen = Set<String>()
        var clustersInOrder: [String] = []
        for span in outcome.spans where !seen.contains(span.speakerID) {
            seen.insert(span.speakerID)
            clustersInOrder.append(span.speakerID)
        }

        // Pass 1: each cluster's nearest known speaker within threshold (or nil).
        // Clusters with too little speech never match — their centroid is noise,
        // however close it lands to someone in the library.
        let durations = speechDuration(byCluster: outcome.spans)
        var match: [String: (name: String, distance: Float)] = [:]
        for cluster in clustersInOrder {
            guard durations[cluster, default: 0] >= minMatchDuration else { continue }
            if let m = bestMatch(
                outcome.embeddings[cluster] ?? [], knownSpeakers, threshold, margin)
            {
                match[cluster] = m
            }
        }

        // A known name must map to at most ONE cluster — the closest. Other
        // clusters that matched the same name fall back to anonymous, so we never
        // print two "Sam" turns (which would also confuse the rename/relearn flow).
        var winnerForName: [String: String] = [:]  // name → winning cluster id
        for (cluster, m) in match {
            if let current = winnerForName[m.name], let cur = match[current],
                cur.distance <= m.distance
            {
                continue
            }
            winnerForName[m.name] = cluster
        }

        // Pass 2: assign labels. Known matches keep their name; everyone else is
        // numbered "Speaker N" by first appearance, starting at 2. "Speaker 1" is
        // reserved by convention for the local user ("Me"), kept stable across
        // meetings even when a given meeting doesn't resolve a "Me" cluster — so the
        // same person doesn't get a different number from one meeting to the next.
        var nextAnon = startingAnon
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

    /// The nearest known speaker (name + distance), or nil — but only when the match
    /// is *confident*: within `threshold`, and at least `margin` closer than the
    /// nearest known speaker with a different name. The margin rejects ambiguous
    /// voiceprints that sit between two enrolled people (a wrong name is worse than
    /// an anonymous "Speaker N").
    private static func bestMatch(
        _ embedding: [Float], _ known: [KnownSpeaker], _ threshold: Float, _ margin: Float
    ) -> (name: String, distance: Float)? {
        let scored = known.map {
            (name: $0.name, distance: VoicePrint.distance(embedding, to: $0.samples))
        }
        guard let best = scored.min(by: { $0.distance < $1.distance }),
            best.distance <= threshold
        else { return nil }
        // The real competitor is the nearest speaker with a DIFFERENT name; the best
        // must clear it by `margin` to be trusted. (No different-named speaker means a
        // single identity in the library — threshold alone decides.)
        if let runnerUp = scored.filter({ $0.name != best.name }).min(by: {
            $0.distance < $1.distance
        }), runnerUp.distance - best.distance < margin {
            return nil
        }
        return best
    }
}
