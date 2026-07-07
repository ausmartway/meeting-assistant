import Foundation

/// Pure operations on a known speaker's set of voice samples: nearest-sample
/// matching and bounded growth. A speaker's print improves as trusted samples
/// arrive; the cap keeps storage and matching cost constant while merge-closest
/// preserves distinct voice modes (headset vs laptop mic vs meeting room).
public enum VoicePrint {
    /// Bound on samples per speaker. Merging (not dropping) at the cap means a
    /// rare-but-real voice mode survives a string of one-off meetings.
    public static let maxSamples = 8

    /// Cosine distance from `embedding` to the *nearest* sample — a person
    /// matches whichever version of their voice is closest. `.infinity` when
    /// there is nothing usable to match against.
    public static func distance(_ embedding: [Float], to samples: [VoiceSample]) -> Float {
        samples.map { VoiceMatch.cosineDistance(embedding, $0.embedding) }.min() ?? .infinity
    }

    /// Add a trusted sample: append below `cap`; at the cap, merge the closest
    /// pair among existing + incoming (duration-weighted) so diversity is kept.
    /// An unusable incoming embedding (empty / zero-magnitude, judged by its own
    /// self-distance) is rejected outright, even against an empty `samples`.
    /// Otherwise, an incoming embedding whose length mismatches every existing
    /// sample also leaves `samples` unchanged.
    public static func adding(
        _ sample: VoiceSample, to samples: [VoiceSample], cap: Int = maxSamples
    ) -> [VoiceSample] {
        // Reject the incoming sample outright when its own embedding is unusable
        // (empty / zero-magnitude): self-distance is `.infinity` exactly in that
        // case. This must be checked independent of `samples` — an empty existing
        // list must not wave through an unusable incoming embedding, and a junk
        // empty-embedding sample already in `samples` must not block all future
        // learning by making every existing distance `.infinity`.
        guard VoiceMatch.cosineDistance(sample.embedding, sample.embedding) != .infinity
        else { return samples }
        guard
            samples.isEmpty
                || samples.contains(where: {
                    VoiceMatch.cosineDistance(sample.embedding, $0.embedding) != .infinity
                })
        else { return samples }
        var all = samples + [sample]
        guard all.count > cap else { return all }
        // Merge the closest pair (there is exactly one over-cap sample).
        var bestPair = (0, 1)
        var bestDistance = Float.infinity
        for i in all.indices {
            for j in all.indices where j > i {
                let d = VoiceMatch.cosineDistance(all[i].embedding, all[j].embedding)
                if d < bestDistance {
                    bestDistance = d
                    bestPair = (i, j)
                }
            }
        }
        let merged = merge(all[bestPair.0], all[bestPair.1])
        all.remove(at: bestPair.1)  // higher index first
        all[bestPair.0] = merged
        return all
    }

    /// Duration-weighted element-wise average; seconds accumulate. Weights are
    /// floored at 1 s so a zero-duration sample can't produce NaNs.
    private static func merge(_ a: VoiceSample, _ b: VoiceSample) -> VoiceSample {
        let wa = Float(max(a.seconds, 1))
        let wb = Float(max(b.seconds, 1))
        let embedding = zip(a.embedding, b.embedding).map { ($0 * wa + $1 * wb) / (wa + wb) }
        return VoiceSample(
            embedding: embedding, seconds: a.seconds + b.seconds,
            addedAt: max(a.addedAt, b.addedAt))
    }
}
