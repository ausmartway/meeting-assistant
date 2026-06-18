import Testing
@testable import MeetingKit

@Suite("TranscriptTitleEditor.retitle")
struct TranscriptTitleEditorTests {

    @Test("replaces the H1 heading, leaving the rest intact")
    func replacesHeading() {
        let doc = "# Microsoft Teams meeting\n2026-06-18\n\n**Speaker:** Hello.\n"
        let out = TranscriptTitleEditor.retitle(doc, to: "Sprint review")
        #expect(out == "# Sprint review\n2026-06-18\n\n**Speaker:** Hello.\n")
    }

    @Test("only the first H1 is changed")
    func onlyFirstHeading() {
        let doc = "# Old\nbody\n# Not a real title\n"
        let out = TranscriptTitleEditor.retitle(doc, to: "New")
        #expect(out == "# New\nbody\n# Not a real title\n")
    }

    @Test("text without an H1 is returned unchanged")
    func noHeading() {
        let doc = "no heading here\njust text"
        #expect(TranscriptTitleEditor.retitle(doc, to: "X") == doc)
    }
}
