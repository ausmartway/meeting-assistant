import Testing

@testable import MeetingKit

@Suite("TranscriptParser")
struct TranscriptParserTests {

    @Test("parses a full document: title, note dropped-or-captured, turns")
    func fullDocument() {
        let doc = """
            # Vault to support ATC training
            2026-06-16T04:53:02Z

            _Transcribed in 2m 30s_

            **[14:53:02] Me:** Skål på skål - Yeah.
            **[14:53:24] Speaker 2:** Thank you.
            """
        let p = TranscriptParser.parse(doc)
        #expect(p.title == "Vault to support ATC training")
        #expect(p.note == "Transcribed in 2m 30s")
        #expect(p.turns.count == 2)
        #expect(
            p.turns[0]
                == TranscriptParser.Turn(
                    time: "14:53:02", speaker: "Me", text: "Skål på skål - Yeah."))
        #expect(
            p.turns[1]
                == TranscriptParser.Turn(time: "14:53:24", speaker: "Speaker 2", text: "Thank you.")
        )
    }

    @Test("the ISO date line is discarded, not turned into a turn or note")
    func dropsISODate() {
        let doc = "# T\n2026-06-16T04:53:02Z\n\n**[00:01] Me:** Hi"
        let p = TranscriptParser.parse(doc)
        #expect(p.title == "T")
        #expect(p.note == nil)
        #expect(p.turns == [TranscriptParser.Turn(time: "00:01", speaker: "Me", text: "Hi")])
    }

    @Test("body-only string (no header) still parses turns")
    func bodyOnly() {
        let doc = "**[00:00] Alice:** Hello there\n**[00:05] Bob:** Hi"
        let p = TranscriptParser.parse(doc)
        #expect(p.title == nil)
        #expect(p.note == nil)
        #expect(p.turns.count == 2)
        #expect(p.turns[0].speaker == "Alice")
        #expect(p.turns[1].text == "Hi")
    }

    @Test("a stray non-turn line after a turn is appended to that turn's text")
    func continuationLine() {
        let doc = "**[00:00] Alice:** First part\nsecond part continues"
        let p = TranscriptParser.parse(doc)
        #expect(p.turns.count == 1)
        #expect(p.turns[0].text == "First part second part continues")
    }

    @Test("empty or non-transcript input yields no turns")
    func garbage() {
        #expect(TranscriptParser.parse("").turns.isEmpty)
        #expect(TranscriptParser.parse("just some prose\nwith no turns").turns.isEmpty)
    }

    @Test("speaker names with spaces parse correctly")
    func multiWordSpeaker() {
        let p = TranscriptParser.parse("**[14:53:25] Cameron Huysman:** That's game day.")
        #expect(
            p.turns.first
                == TranscriptParser.Turn(
                    time: "14:53:25", speaker: "Cameron Huysman", text: "That's game day."))
    }
}
