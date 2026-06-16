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

    @Test("with a base date, stamps each turn with the real wall-clock time")
    func realClockTimestamps() {
        // 1970-01-01 00:00:00 UTC as the recording start (deterministic).
        let base = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(identifier: "UTC")!
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "first", speaker: "Me"),
            LabeledSegment(start: 65, end: 70, text: "later", speaker: "Alice"),
        ]
        let md = TranscriptFormatter.transcriptBody(segments, baseDate: base, timeZone: utc)
        #expect(md == "**[00:00:00] Me:** first\n**[00:01:05] Alice:** later")
    }

    // MARK: - document() — the full file that gets written to transcript.md and
    // that the rename flow reads back and rewrites, so its shape is load-bearing.

    private func meeting() -> Meeting {
        Meeting(id: "m1", title: "Weekly Sync",
                startDate: Date(timeIntervalSince1970: 0),
                endDate: Date(timeIntervalSince1970: 3600),
                provider: .zoom, joinURL: nil)
    }

    @Test("document() includes the title header, the note, and the transcript body")
    func documentFull() {
        let segs = [LabeledSegment(start: 0, end: 2, text: "Hi", speaker: "Me")]
        let doc = TranscriptFormatter.document(
            meeting: meeting(), segments: segs,
            baseDate: Date(timeIntervalSince1970: 0), note: "Transcribed in 5s")
        #expect(doc.hasPrefix("# Weekly Sync\n"))
        #expect(doc.contains("_Transcribed in 5s_"))
        #expect(doc.contains("Me:** Hi"))
    }

    @Test("document() still produces a valid titled file when there are no segments")
    func documentEmpty() {
        let doc = TranscriptFormatter.document(meeting: meeting(), segments: [])
        #expect(doc.hasPrefix("# Weekly Sync\n"))
        // No note line when none is supplied, and the body is empty — but the file
        // is still well-formed (title + date), never nil/garbage.
        #expect(!doc.contains("_"))
    }
}
