import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingStore segments")
struct MeetingStoreSegmentsTests {

    /// A store rooted in a fresh temp directory, isolated per test.
    private func makeTempStore() throws -> MeetingStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "MeetingStoreSegmentsTests-\(UUID().uuidString)", isDirectory: true)
        return try MeetingStore(root: tmp)
    }

    @Test("segments round-trip through segments.json")
    func roundTrip() throws {
        let store = try makeTempStore()
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "hi", speaker: "Me", channel: .microphone),
            LabeledSegment(start: 2, end: 5, text: "yo", speaker: "Sam", channel: .system),
        ]
        try store.saveSegments(segments, for: "m1")
        #expect(store.segments(for: "m1") == segments)
    }

    @Test("missing segments.json returns nil")
    func missing() throws {
        let store = try makeTempStore()
        #expect(store.segments(for: "nope") == nil)
    }
}
