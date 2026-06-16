import Testing
import Foundation
@testable import MeetingKit

@Suite("DiarizationLabeler")
struct DiarizationLabelerTests {

    private func span(_ start: Double, _ end: Double, _ id: String) -> DiarizedSpan {
        DiarizedSpan(start: start, end: end, speakerID: id)
    }

    @Test("enrolled 'Me' stays Me; others numbered from 2 by first appearance")
    func displayLabels() {
        let spans = [
            span(0, 1, "Me"),
            span(1, 2, "spk_a"),
            span(2, 3, "spk_b"),
            span(3, 4, "spk_a"),   // repeat keeps its number
        ]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(labels["Me"] == "Me")
        #expect(labels["spk_a"] == "Speaker 2")
        #expect(labels["spk_b"] == "Speaker 3")
    }

    @Test("numbering is by first appearance regardless of id ordering")
    func numberingOrder() {
        let spans = [span(0, 1, "zzz"), span(1, 2, "aaa")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(labels["zzz"] == "Speaker 2")
        #expect(labels["aaa"] == "Speaker 3")
    }

    @Test("speaker(at:) returns the label of the span containing the time")
    func speakerAtContained() {
        let spans = [span(0, 2, "Me"), span(2, 4, "spk_a")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(DiarizationLabeler.speaker(at: 1.0, spans: spans, labels: labels) == "Me")
        #expect(DiarizationLabeler.speaker(at: 3.0, spans: spans, labels: labels) == "Speaker 2")
    }

    @Test("speaker(at:) returns nil when the time is in a gap between spans")
    func speakerAtGap() {
        let spans = [span(0, 1, "Me"), span(2, 3, "spk_a")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(DiarizationLabeler.speaker(at: 1.5, spans: spans, labels: labels) == nil)
    }

    @Test("span end is exclusive: a time exactly on a boundary belongs to the next span")
    func boundaryExclusive() {
        let spans = [span(0, 2, "Me"), span(2, 4, "spk_a")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(DiarizationLabeler.speaker(at: 2.0, spans: spans, labels: labels) == "Speaker 2")
    }
}
