import Foundation
import Testing

@testable import MeetingKit

@Suite("SpeakerTimelineConsolidator")
struct SpeakerTimelineConsolidatorTests {

    /// Build a timeline from (timestamp, name?) pairs.
    private func timeline(_ pairs: [(TimeInterval, String?)]) -> SpeakerTimeline {
        SpeakerTimeline(samples: pairs.map { SpeakerSample(timestamp: $0.0, speakerName: $0.1) })
    }

    private func names(_ t: SpeakerTimeline) -> [String?] {
        t.samples.map(\.speakerName)
    }

    @Test("empty timeline passes through")
    func empty() {
        let out = SpeakerTimelineConsolidator.consolidate(timeline([]))
        #expect(out.samples.isEmpty)
    }

    @Test("variant snapping rewrites all members to the most-frequent display")
    func variantSnapping() {
        // The John cluster: "John Smith" twice + one whitespace/case variant.
        // Jane is kept in two adjacent samples so Step B (Task 4) won't later
        // treat her as an isolated outlier — this test isolates Step A's behavior.
        let input = timeline([
            (0, "John Smith"), (1, "John Smith"), (2, "john  smith"),
            (3, "Jane Doe"), (4, "Jane Doe"),
        ])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        // The whitespace/case variant at index 2 snaps to the winning "John Smith".
        #expect(names(out) == ["John Smith", "John Smith", "John Smith", "Jane Doe", "Jane Doe"])
    }

    @Test("timestamps are preserved")
    func timestampsPreserved() {
        let input = timeline([(0, "A B"), (5, "a  b")])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(out.samples.map(\.timestamp) == [0, 5])
    }
}
