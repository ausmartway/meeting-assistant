import Foundation
import Testing

@testable import MeetingKit

@Suite("LabeledSegment.channel")
struct LabeledSegmentChannelTests {

    @Test("channel round-trips through JSON")
    func roundTrip() throws {
        let seg = LabeledSegment(
            start: 1, end: 2, text: "hi", speaker: "Sam", channel: .system)
        let decoded = try JSONDecoder().decode(
            LabeledSegment.self, from: JSONEncoder().encode(seg))
        #expect(decoded.channel == .system)
    }

    @Test("JSON without a channel key decodes to nil (legacy)")
    func legacyDecode() throws {
        let legacy = """
            {"start": 1, "end": 2, "text": "hi", "speaker": "Sam"}
            """
        let decoded = try JSONDecoder().decode(
            LabeledSegment.self, from: Data(legacy.utf8))
        #expect(decoded.channel == nil)
    }

    @Test("fuse carries each source segment's channel")
    func fuseCarriesChannel() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "a", channel: .microphone),
            TranscriptSegment(start: 1, end: 2, text: "b", channel: .system),
        ]
        let labeled = SpeakerFuser.fuse(
            segments: segments, timeline: SpeakerTimeline(samples: []))
        #expect(labeled.map(\.channel) == [.microphone, .system])
    }
}
