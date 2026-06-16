import Foundation
import Testing
@testable import MeetingKit

@Suite("TranscriptRelabeler")
struct TranscriptRelabelerTests {

    /// Build a transcript using the REAL formatter so tests exercise the exact
    /// emitted line shape rather than a hand-typed guess.
    private func transcript(_ segments: [LabeledSegment]) -> String {
        TranscriptFormatter.transcriptBody(segments)
    }

    @Test("renames every line belonging to the target speaker")
    func renamesTargetSpeaker() {
        // Interleave a third turn so Speaker 2 produces two distinct lines (the
        // formatter merges *consecutive* same-speaker turns into one).
        let body = transcript([
            LabeledSegment(start: 0, end: 2, text: "Hi, good morning.", speaker: "Speaker 2"),
            LabeledSegment(start: 2, end: 4, text: "Hello there.", speaker: "Speaker 1"),
            LabeledSegment(start: 6, end: 8, text: "Anything else?", speaker: "Speaker 2"),
        ])

        let renamed = TranscriptRelabeler.rename(in: body, from: "Speaker 2", to: "Sam")

        // Both of Speaker 2's turns now carry the new label.
        #expect(renamed.contains("] Sam:** Hi, good morning."))
        #expect(renamed.contains("] Sam:** Anything else?"))
        // The old label no longer appears as a speaker label.
        #expect(!renamed.contains("] Speaker 2:**"))
    }

    @Test("leaves other speakers' lines untouched")
    func leavesOtherSpeakersUntouched() {
        let body = transcript([
            LabeledSegment(start: 0, end: 2, text: "Hello there.", speaker: "Speaker 1"),
            LabeledSegment(start: 2, end: 4, text: "Hi, good morning.", speaker: "Speaker 2"),
        ])

        let renamed = TranscriptRelabeler.rename(in: body, from: "Speaker 2", to: "Sam")

        #expect(renamed.contains("] Speaker 1:** Hello there."))
    }

    @Test("does not alter body text that mentions the old label")
    func doesNotAlterBodyText() {
        let body = transcript([
            LabeledSegment(start: 0, end: 2, text: "Speaker 2 is loud.", speaker: "Speaker 1"),
            LabeledSegment(start: 2, end: 4, text: "Sorry about that.", speaker: "Speaker 2"),
        ])

        let renamed = TranscriptRelabeler.rename(in: body, from: "Speaker 2", to: "Sam")

        // Speaker 1's spoken words are preserved verbatim, including "Speaker 2".
        #expect(renamed.contains("] Speaker 1:** Speaker 2 is loud."))
        // Speaker 2's own label was rewritten.
        #expect(renamed.contains("] Sam:** Sorry about that."))
    }
}
