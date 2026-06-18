import Foundation
import Testing

@testable import MeetingKit

@Suite struct TranscriptionETATests {
    // Default gates: minFraction 0.03, minElapsed 3, smoothing 0.3.

    @Test func noEstimateBeforeGates() {
        var eta = TranscriptionETA()
        // fraction below minFraction → no estimate yet
        #expect(eta.update(elapsed: 5, fraction: 0.01) == nil)
        // elapsed below minElapsed → no estimate yet
        #expect(eta.update(elapsed: 1, fraction: 0.5) == nil)
    }

    @Test func steadyProgressCountsDown() {
        var eta = TranscriptionETA()
        // 10s elapsed, 25% done → raw = 10*(0.75/0.25) = 30s  → "under a minute"
        let a = eta.update(elapsed: 10, fraction: 0.25)
        // 20s elapsed, 50% done → raw = 20*(0.5/0.5) = 20s (falls freely) → "under a minute"
        let b = eta.update(elapsed: 20, fraction: 0.50)
        // 30s elapsed, 75% done → raw = 30*(0.25/0.75) = 10s (falls freely) → "almost done"
        let c = eta.update(elapsed: 30, fraction: 0.75)
        #expect(a == "under a minute")  // 30s → 20..45 bucket
        #expect(b == "under a minute")  // 20s → 20..45 bucket (boundary)
        #expect(c == "almost done")  // 10s → <20
    }

    @Test func upwardBlipIsDamped() {
        var eta = TranscriptionETA()
        // Establish a low estimate: 30s elapsed, 90% done → raw ~3.3s
        _ = eta.update(elapsed: 30, fraction: 0.90)
        // A noisy backward fraction (interleaved channels): 31s, 50% → raw=31s.
        // Must NOT jump straight to a ~31s estimate; gentle rise only.
        let after = eta.update(elapsed: 31, fraction: 0.50)
        // prev ~3.33; gentle rise = prev + 0.3*(31-3.33) ≈ 11.6s → "almost done"
        #expect(after == "almost done")
    }

    @Test func minutesBucketRoundsToNearest() {
        // ≥90s → "~N min left" rounded to nearest minute.
        #expect(TranscriptionETA.label(for: 90) == "~2 min left")  // 1.5 → 2
        #expect(TranscriptionETA.label(for: 130) == "~2 min left")  // 2.17 → 2
        #expect(TranscriptionETA.label(for: 200) == "~3 min left")  // 3.33 → 3
    }

    @Test func subMinuteBuckets() {
        #expect(TranscriptionETA.label(for: 80) == "~1 min left")  // 45..90
        #expect(TranscriptionETA.label(for: 45) == "~1 min left")  // boundary
        #expect(TranscriptionETA.label(for: 30) == "under a minute")  // 20..45
        #expect(TranscriptionETA.label(for: 20) == "under a minute")  // boundary
        #expect(TranscriptionETA.label(for: 10) == "almost done")  // <20
    }

    @Test func resetClearsState() {
        var eta = TranscriptionETA()
        _ = eta.update(elapsed: 10, fraction: 0.25)
        eta.reset()
        // After reset, a below-gate sample yields nil again (no carried estimate).
        #expect(eta.update(elapsed: 1, fraction: 0.5) == nil)
    }
}
