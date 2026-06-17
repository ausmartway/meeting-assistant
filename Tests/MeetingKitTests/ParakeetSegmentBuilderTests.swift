import Testing
import Foundation
@testable import MeetingKit

@Suite("ParakeetSegmentBuilder")
struct ParakeetSegmentBuilderTests {

    private func tok(_ token: String, _ start: Double, _ end: Double) -> ParakeetToken {
        ParakeetToken(token: token, startTime: start, endTime: end)
    }

    @Test("splits tokens into sentence segments on terminal punctuation")
    func splitsOnPunctuation() {
        let tokens = [
            tok(" Hello", 0.0, 0.4), tok(" there", 0.4, 0.8), tok(".", 0.8, 0.9),
            tok(" How", 1.0, 1.3), tok(" are", 1.3, 1.5), tok(" you", 1.5, 1.8), tok("?", 1.8, 1.9),
        ]
        let segs = ParakeetSegmentBuilder.segments(
            tokens: tokens, channel: .system, fallbackText: "ignored", fallbackDuration: 2.0
        )
        #expect(segs.count == 2)
        #expect(segs[0].text == "Hello there.")
        #expect(segs[0].start == 0.0)
        #expect(segs[0].end == 0.9)
        #expect(segs[0].channel == .system)
        #expect(segs[1].text == "How are you?")
        #expect(segs[1].start == 1.0)
        #expect(segs[1].end == 1.9)
    }

    @Test("splits on a long pause even without punctuation")
    func splitsOnPause() {
        let tokens = [
            tok(" one", 0.0, 0.4), tok(" two", 0.4, 0.8),
            tok(" three", 3.0, 3.4),   // 2.2s gap > 1.0s threshold
        ]
        let segs = ParakeetSegmentBuilder.segments(
            tokens: tokens, channel: .microphone, fallbackText: "x", fallbackDuration: 4.0
        )
        #expect(segs.count == 2)
        #expect(segs[0].text == "one two")
        #expect(segs[1].text == "three")
        #expect(segs[1].channel == .microphone)
    }

    @Test("with no tokens, emits a single fallback segment spanning the audio")
    func fallbackWhenNoTimings() {
        let segs = ParakeetSegmentBuilder.segments(
            tokens: [], channel: .system, fallbackText: "whole thing", fallbackDuration: 12.5
        )
        #expect(segs.count == 1)
        #expect(segs[0].text == "whole thing")
        #expect(segs[0].start == 0.0)
        #expect(segs[0].end == 12.5)
        #expect(segs[0].channel == .system)
    }

    @Test("trims whitespace and skips empty results")
    func trimsAndSkipsEmpty() {
        let segs = ParakeetSegmentBuilder.segments(
            tokens: [tok("   ", 0.0, 0.1)], channel: .system, fallbackText: "fb", fallbackDuration: 1.0
        )
        #expect(segs.count == 1)
        #expect(segs[0].text == "fb")
    }
}
