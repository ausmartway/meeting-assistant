import Foundation
import Testing

@testable import MeetingKit

@Suite("SlideChangeDetector.decide")
struct SlideDecisionTests {

    /// A uniform signature of the given brightness — the simplest way to build two
    /// frames a known distance apart (diff is |a-b|/255 for uniform frames).
    private func flat(_ value: UInt8) -> FrameSignature {
        FrameSignature(cells: [UInt8](repeating: value, count: 256))
    }

    @Test("the first sample reports stillDistance == nil (no predecessor)")
    func firstSampleHasNoStillDistance() {
        var d = SlideChangeDetector()
        let decision = d.decide(flat(10), at: 0)
        #expect(decision.save == false)
        #expect(decision.stillDistance == nil)
        #expect(decision.changeDistance == nil)
    }

    @Test("a still-and-new frame reports both distances with save == true")
    func stillAndNewReportsBothDistances() {
        var d = SlideChangeDetector()
        _ = d.decide(flat(10), at: 0)  // primes `previous`
        let decision = d.decide(flat(10), at: 2.5)
        #expect(decision.save == true)
        #expect(decision.stillDistance == 0)  // identical to previous sample
        #expect(decision.changeDistance == nil)  // no keyframe kept yet
    }

    @Test("a moving frame reports a stillDistance above threshold with save == false")
    func movingFrameReportsHighStillDistance() {
        var d = SlideChangeDetector()
        _ = d.decide(flat(0), at: 0)
        let decision = d.decide(flat(120), at: 2.5)
        #expect(decision.save == false)
        #expect(decision.stillDistance != nil)
        #expect(decision.stillDistance! > d.stillThreshold)
    }

    @Test("consider still agrees with decide(...).save for the same input sequence")
    func considerAgreesWithDecide() {
        var viaConsider = SlideChangeDetector()
        var viaDecide = SlideChangeDetector()
        let frames: [(FrameSignature, TimeInterval)] = [
            (flat(10), 0), (flat(10), 2.5), (flat(200), 20), (flat(200), 22.5), (flat(200), 40),
        ]
        for (signature, t) in frames {
            #expect(
                viaConsider.consider(signature, at: t) == viaDecide.decide(signature, at: t).save)
        }
    }

    @Test("isExhausted flips once the cap is reached")
    func isExhaustedFlipsAtCap() {
        var d = SlideChangeDetector(minInterval: 0, maxKeyframes: 2)
        var t = 0.0
        // Alternate settled content so every other sample is a fresh, still slide;
        // the first two saves reach the cap of 2.
        let values: [UInt8] = [10, 10, 200, 200, 10, 10]
        for (i, value) in values.enumerated() {
            #expect(d.isExhausted == (i >= 4))  // saves land at indices 1 and 3
            _ = d.consider(flat(value), at: t)
            t += 2.5
        }
        #expect(d.isExhausted == true)
    }
}
