import Testing

@testable import MeetingKit

@Suite("SlideChangeDetector")
struct SlideChangeDetectorTests {

    /// A uniform signature of the given brightness — the simplest way to build two
    /// frames a known distance apart (diff is |a-b|/255 for uniform frames).
    private func flat(_ value: UInt8) -> FrameSignature {
        FrameSignature(cells: [UInt8](repeating: value, count: 256))
    }

    @Test("the very first sample never saves (no predecessor to prove it is still)")
    func firstSampleSkips() {
        var d = SlideChangeDetector()
        #expect(d.consider(flat(10), at: 0) == false)
    }

    @Test("a still frame that differs from the last keyframe saves")
    func stillAndDifferentSaves() {
        var d = SlideChangeDetector()
        #expect(d.consider(flat(10), at: 0) == false)  // primes `previous`
        #expect(d.consider(flat(10), at: 2.5) == true)  // still, and no keyframe yet
    }

    @Test("a still frame identical to the last keyframe does not save again")
    func stillAndSameSkips() {
        var d = SlideChangeDetector()
        _ = d.consider(flat(10), at: 0)
        #expect(d.consider(flat(10), at: 2.5) == true)
        #expect(d.consider(flat(10), at: 10) == false)  // same content → nothing new
    }

    @Test("a moving picture never saves, however different it is")
    func movingSkips() {
        var d = SlideChangeDetector()
        _ = d.consider(flat(0), at: 0)
        // Each sample is far from the previous one — a talking head, not a slide.
        #expect(d.consider(flat(120), at: 2.5) == false)
        #expect(d.consider(flat(0), at: 5) == false)
        #expect(d.consider(flat(120), at: 7.5) == false)
    }

    @Test("a new slide saves once it settles")
    func newSlideSavesWhenSettled() {
        var d = SlideChangeDetector()
        _ = d.consider(flat(10), at: 0)
        #expect(d.consider(flat(10), at: 2.5) == true)  // slide 1
        #expect(d.consider(flat(200), at: 20) == false)  // mid-flip: not still yet
        #expect(d.consider(flat(200), at: 22.5) == true)  // settled → slide 2
    }

    @Test("minInterval blocks a save that is too soon after the last one")
    func minIntervalRespected() {
        var d = SlideChangeDetector(minInterval: 5)
        _ = d.consider(flat(10), at: 0)
        #expect(d.consider(flat(10), at: 2.5) == true)  // saves at t=2.5
        _ = d.consider(flat(200), at: 3)  // flip, not still
        #expect(d.consider(flat(200), at: 4) == false)  // still + new, but only 1.5s later
        #expect(d.consider(flat(200), at: 8) == true)  // past the 5s floor
    }

    @Test("maxKeyframes caps a pathological meeting")
    func capEnforced() {
        var d = SlideChangeDetector(minInterval: 0, maxKeyframes: 2)
        var t = 0.0
        var saved = 0
        // Alternate settled content so every other sample is a fresh, still slide.
        for value: UInt8 in [10, 10, 200, 200, 10, 10, 200, 200] {
            if d.consider(flat(value), at: t) { saved += 1 }
            t += 2.5
        }
        #expect(saved == 2)
    }

    @Test("thresholds are configurable")
    func thresholdsConfigurable() {
        // A 20/255 ≈ 0.078 step counts as "still" only under a loose threshold.
        var strict = SlideChangeDetector(stillThreshold: 0.02)
        _ = strict.consider(flat(10), at: 0)
        #expect(strict.consider(flat(30), at: 2.5) == false)

        var loose = SlideChangeDetector(stillThreshold: 0.2)
        _ = loose.consider(flat(10), at: 0)
        #expect(loose.consider(flat(30), at: 2.5) == true)
    }

    @Test("distance returns 1 for signatures with different cell counts")
    func distanceMismatchedSizes() {
        let sig1 = FrameSignature(cells: [UInt8](repeating: 10, count: 256))
        let sig2 = FrameSignature(cells: [UInt8](repeating: 10, count: 100))
        #expect(sig1.distance(to: sig2) == 1)
    }

    @Test("distance returns 1 for two empty signatures")
    func distanceEmptySignatures() {
        let empty1 = FrameSignature(cells: [])
        let empty2 = FrameSignature(cells: [])
        #expect(empty1.distance(to: empty2) == 1)
    }
}
