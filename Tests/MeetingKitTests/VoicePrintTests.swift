import Foundation
import Testing

@testable import MeetingKit

@Suite("VoicePrint")
struct VoicePrintTests {
    private func sample(_ e: [Float], seconds: TimeInterval = 60) -> VoiceSample {
        VoiceSample(embedding: e, seconds: seconds, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("distance is the minimum over samples")
    func minDistance() {
        let samples = [sample([1, 0, 0]), sample([0, 1, 0])]
        // Exactly matches the second sample → distance 0, not the average.
        #expect(VoicePrint.distance([0, 1, 0], to: samples) == 0)
    }

    @Test("distance to no samples is infinity (cannot match)")
    func emptySamples() {
        #expect(VoicePrint.distance([1, 0, 0], to: []) == .infinity)
    }

    @Test("adding below the cap appends")
    func addAppends() {
        let out = VoicePrint.adding(sample([0, 1, 0]), to: [sample([1, 0, 0])])
        #expect(out.count == 2)
    }

    @Test("adding at the cap merges the closest pair, preserving diversity")
    func addMergesClosest() {
        // Two near-identical "headset" samples + one distinct "room" sample, cap 3.
        let headsetA = sample([1, 0, 0], seconds: 60)
        let headsetB = sample([0.99, 0.14, 0], seconds: 30)  // ~0.01 from headsetA
        let room = sample([0, 0, 1], seconds: 60)
        let incoming = sample([0, 1, 0], seconds: 60)  // far from all
        let out = VoicePrint.adding(incoming, to: [headsetA, headsetB, room], cap: 3)
        #expect(out.count == 3)
        // The room and incoming samples survive untouched; the two headset
        // samples merged into one.
        #expect(out.contains(room))
        #expect(out.contains(incoming))
        #expect(!out.contains(headsetA) && !out.contains(headsetB))
    }

    @Test("merged sample is duration-weighted and accumulates seconds")
    func mergeWeights() {
        // Cap 1: incoming must merge with the only existing sample.
        let old = sample([1, 0, 0], seconds: 90)
        let new = sample([0, 1, 0], seconds: 30)
        let out = VoicePrint.adding(new, to: [old], cap: 1)
        #expect(out.count == 1)
        #expect(out[0].seconds == 120)
        // 90:30 weighting → (0.75, 0.25, 0).
        #expect(abs(out[0].embedding[0] - 0.75) < 0.001)
        #expect(abs(out[0].embedding[1] - 0.25) < 0.001)
    }

    @Test("unusable incoming embeddings are ignored")
    func unusableIgnored() {
        let existing = [sample([1, 0, 0])]
        #expect(VoicePrint.adding(sample([], seconds: 60), to: existing) == existing)
        #expect(VoicePrint.adding(sample([0, 0, 0], seconds: 60), to: existing) == existing)
    }
}
