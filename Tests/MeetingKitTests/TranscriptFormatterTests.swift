import Testing
import Foundation
@testable import MeetingKit

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {

    @Test("formats timestamps as mm:ss and one line per speaker turn")
    func basicFormatting() {
        let segments = [
            LabeledSegment(start: 0, end: 3, text: "Hi all", speaker: "Me"),
            LabeledSegment(start: 65, end: 70, text: "point one", speaker: "Alice"),
        ]
        let md = TranscriptFormatter.transcriptBody(segments)
        #expect(md == "**[00:00] Me:** Hi all\n**[01:05] Alice:** point one")
    }

    @Test("merges consecutive segments from the same speaker into one turn")
    func mergesConsecutiveSameSpeaker() {
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "Hello", speaker: "Alice"),
            LabeledSegment(start: 2, end: 4, text: "and welcome", speaker: "Alice"),
            LabeledSegment(start: 4, end: 6, text: "Thanks", speaker: "Bob"),
        ]
        let md = TranscriptFormatter.transcriptBody(segments)
        #expect(md == "**[00:00] Alice:** Hello and welcome\n**[00:04] Bob:** Thanks")
    }

    @Test("renders an hour-plus timestamp correctly")
    func hourPlusTimestamp() {
        let segments = [LabeledSegment(start: 3661, end: 3665, text: "late", speaker: "Me")]
        let md = TranscriptFormatter.transcriptBody(segments)
        #expect(md == "**[01:01:01] Me:** late")
    }

    @Test("returns an empty string for no segments")
    func emptyInput() {
        #expect(TranscriptFormatter.transcriptBody([]) == "")
    }
}
