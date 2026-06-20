import Foundation

/// Multi-frame voting over an OCR active-speaker timeline.
///
/// OCR is the fragile signal (see `SpeakerSampler`), so a per-frame name can be a
/// misread that then "holds" until the next sample in `SpeakerFuser`. This pure,
/// deterministic pass cleans the timeline before fusion in two steps:
///
///  - **A. Variant snapping** — trivial variants of one name (whitespace/case/
///    role-suffix) are grouped by `SpeakerNameNormalizer.canonicalKey` and the
///    most-frequent display variant in each group wins.
///  - **B. Isolated-outlier suppression** — a lone differing read between two
///    samples of the same other name is treated as noise (added in Task 4).
///
/// Runs in `MeetingProcessor` post-processing, never in the live capture path.
public enum SpeakerTimelineConsolidator {

    public static func consolidate(_ timeline: SpeakerTimeline) -> SpeakerTimeline {
        let snapped = snapVariants(timeline.samples)
        let cleaned = suppressIsolatedOutliers(snapped)
        return SpeakerTimeline(samples: cleaned)
    }

    /// Step A: rewrite every named sample to the most-frequent display in its
    /// canonical-key cluster. Ties broken by first appearance for determinism.
    private static func snapVariants(_ samples: [SpeakerSample]) -> [SpeakerSample] {
        // For each canonical key: counts per display, and first-seen order.
        var counts: [String: [String: Int]] = [:]
        var firstSeen: [String: Int] = [:]
        for (i, s) in samples.enumerated() {
            guard let name = s.speakerName else { continue }
            let key = SpeakerNameNormalizer.canonicalKey(name)
            counts[key, default: [:]][name, default: 0] += 1
            if firstSeen[name] == nil { firstSeen[name] = i }
        }
        // Winning display per key: highest count; ties broken by earliest first-seen.
        var winner: [String: String] = [:]
        for (key, byDisplay) in counts {
            winner[key] =
                byDisplay.max { a, b in
                    if a.value != b.value { return a.value < b.value }
                    return (firstSeen[a.key] ?? 0) > (firstSeen[b.key] ?? 0)
                }?.key
        }
        return samples.map { s in
            guard let name = s.speakerName else { return s }
            let key = SpeakerNameNormalizer.canonicalKey(name)
            return SpeakerSample(timestamp: s.timestamp, speakerName: winner[key] ?? name)
        }
    }

    /// Step B: a single sample whose name differs from BOTH its immediate
    /// neighbors is a likely misread. If the two neighbors agree, adopt their
    /// name; if they disagree (or a neighbor is missing), drop to nil. A name that
    /// persists across two or more adjacent samples is never suppressed.
    private static func suppressIsolatedOutliers(_ samples: [SpeakerSample]) -> [SpeakerSample] {
        guard samples.count >= 3 else { return samples }
        var result = samples
        for i in 1..<(samples.count - 1) {
            let prev = samples[i - 1].speakerName
            let curr = samples[i].speakerName
            let next = samples[i + 1].speakerName
            guard let curr, curr != prev, curr != next else { continue }
            // curr is isolated (differs from both neighbors).
            let replacement = (prev != nil && prev == next) ? prev : nil
            result[i] = SpeakerSample(timestamp: samples[i].timestamp, speakerName: replacement)
        }
        return result
    }
}
