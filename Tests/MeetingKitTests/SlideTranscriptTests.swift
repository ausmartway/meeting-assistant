import Foundation
import Testing

@testable import MeetingKit

@Suite("Slides in the transcript")
struct SlideTranscriptTests {

    private func segment(_ start: TimeInterval, _ speaker: String, _ text: String)
        -> LabeledSegment
    {
        LabeledSegment(start: start, end: start + 5, text: text, speaker: speaker)
    }

    private var base: Date { Date(timeIntervalSince1970: 0) }

    @Test("no slides reproduces today's output exactly")
    func emptySlidesUnchanged() {
        let segs = [segment(0, "Me", "hello"), segment(10, "Ada", "hi")]
        let withArg = TranscriptFormatter.transcriptBody(segs, baseDate: base, slides: [])
        let without = TranscriptFormatter.transcriptBody(segs, baseDate: base)
        #expect(withArg == without)
    }

    @Test("a slide is written after the last turn that started before it")
    func slideInterleaved() {
        let segs = [segment(0, "Me", "hello"), segment(60, "Ada", "hi")]
        let utc = TimeZone(identifier: "UTC")!
        let body = TranscriptFormatter.transcriptBody(
            segs, baseDate: base, timeZone: utc,
            slides: [SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg")])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("hello"))
        #expect(lines[1] == "![Shared screen 00:00:30](slides/slide-0030.jpg)")
        #expect(lines[2].contains("hi"))
    }

    @Test("a slide before any speech leads the body")
    func slideBeforeFirstTurn() {
        let utc = TimeZone(identifier: "UTC")!
        let body = TranscriptFormatter.transcriptBody(
            [segment(60, "Ada", "hi")], baseDate: base, timeZone: utc,
            slides: [SlideKeyframe(timestamp: 5, file: "slides/slide-0005.jpg")])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines[0] == "![Shared screen 00:00:05](slides/slide-0005.jpg)")
        #expect(lines[1].contains("hi"))
    }

    @Test("a slide after all speech trails the body")
    func slideAfterLastTurn() {
        let utc = TimeZone(identifier: "UTC")!
        let body = TranscriptFormatter.transcriptBody(
            [segment(0, "Me", "hello")], baseDate: base, timeZone: utc,
            slides: [SlideKeyframe(timestamp: 600, file: "slides/slide-0600.jpg")])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[1] == "![Shared screen 00:10:00](slides/slide-0600.jpg)")
    }

    @Test("several slides between two turns keep their order")
    func multipleSlidesOrdered() {
        let utc = TimeZone(identifier: "UTC")!
        let body = TranscriptFormatter.transcriptBody(
            [segment(0, "Me", "hello"), segment(600, "Ada", "hi")], baseDate: base, timeZone: utc,
            slides: [
                SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg"),
                SlideKeyframe(timestamp: 90, file: "slides/slide-0090.jpg"),
            ])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines[1].contains("slide-0030.jpg"))
        #expect(lines[2].contains("slide-0090.jpg"))
    }

    @Test("document() carries slides into the rendered document")
    func documentIncludesSlides() {
        let meeting = Meeting(
            id: "m1", title: "Sync", startDate: base, endDate: base.addingTimeInterval(1800),
            provider: nil, joinURL: nil)
        let doc = TranscriptFormatter.document(
            meeting: meeting, segments: [segment(0, "Me", "hello")], baseDate: base,
            note: nil, slides: [SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg")])
        #expect(doc.contains("![Shared screen "))
        #expect(doc.contains("](slides/slide-0030.jpg)"))
    }

    // MARK: - Parsing back

    private var documentWithSlide: String {
        """
        # Sync
        1970-01-01T00:00:00Z

        **[00:00:00] Me:** hello
        ![Shared screen 00:00:30](slides/slide-0030.jpg)
        **[00:10:00] Ada:** hi
        """
    }

    @Test("a slide line is parsed into slides, not turns")
    func slideParsedSeparately() {
        let parsed = TranscriptParser.parse(documentWithSlide)
        #expect(parsed.turns.count == 2)
        #expect(parsed.slides.count == 1)
        #expect(parsed.slides[0].file == "slides/slide-0030.jpg")
        #expect(parsed.slides[0].time == "00:00:30")
        #expect(parsed.slides[0].afterTurnIndex == 0)
    }

    @Test("turns are identical with and without slide lines (R27 playback can't regress)")
    func turnsUnaffectedBySlides() {
        let withoutSlide =
            documentWithSlide
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("![") }
            .joined(separator: "\n")
        #expect(
            TranscriptParser.parse(documentWithSlide).turns
                == TranscriptParser.parse(withoutSlide).turns)
    }

    @Test("a slide before the first turn gets index -1")
    func slideBeforeFirstTurnParsed() {
        let doc = """
            # Sync
            1970-01-01T00:00:00Z

            ![Shared screen 00:00:05](slides/slide-0005.jpg)
            **[00:01:00] Ada:** hi
            """
        let parsed = TranscriptParser.parse(doc)
        #expect(parsed.slides.count == 1)
        #expect(parsed.slides[0].afterTurnIndex == -1)
        #expect(parsed.turns.count == 1)
        #expect(parsed.title == "Sync")  // the slide line didn't eat the header
    }

    @Test("a malformed image line doesn't corrupt the preceding turn")
    func malformedImageLineIgnored() {
        let doc = """
            **[00:00:00] Me:** hello
            ![Shared screen 00:00:30
            """
        let parsed = TranscriptParser.parse(doc)
        #expect(parsed.slides.isEmpty)
        #expect(parsed.turns.count == 1)
        // It falls through to the stray-line rule, which appends it to the last turn —
        // ugly but lossless, and it never fabricates a slide.
        #expect(parsed.turns[0].text.hasPrefix("hello"))
    }

    @Test("a formatted document round-trips through the parser")
    func roundTrip() {
        let meeting = Meeting(
            id: "m1", title: "Sync", startDate: base, endDate: base.addingTimeInterval(1800),
            provider: nil, joinURL: nil)
        let doc = TranscriptFormatter.document(
            meeting: meeting,
            segments: [segment(0, "Me", "hello"), segment(600, "Ada", "hi")],
            baseDate: base, note: nil,
            slides: [SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg")])
        let parsed = TranscriptParser.parse(doc)
        #expect(parsed.turns.count == 2)
        #expect(parsed.slides.count == 1)
        #expect(parsed.slides[0].afterTurnIndex == 0)
    }
}
