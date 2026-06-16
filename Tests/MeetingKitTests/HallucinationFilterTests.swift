import Testing
@testable import MeetingKit

@Suite("HallucinationFilter")
struct HallucinationFilterTests {

    private func seg(_ text: String) -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1, text: text, channel: .system)
    }

    @Test("drops bracketed non-speech tags like [MUSIC] and [BLANK_AUDIO]")
    func dropsBracketedTags() {
        let input = [seg("[MUSIC]"), seg("[BLANK_AUDIO]"), seg("Hello team")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["Hello team"])
    }

    @Test("drops parenthesized non-speech tags like (silence)")
    func dropsParenthesizedTags() {
        let input = [seg("(silence)"), seg("(upbeat music)"), seg("Let's begin")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["Let's begin"])
    }

    @Test("drops empty and whitespace-only segments")
    func dropsEmpty() {
        let input = [seg(""), seg("   "), seg("\n"), seg("Real words")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["Real words"])
    }

    @Test("drops known stock hallucination phrases regardless of case")
    func dropsKnownPhrases() {
        let input = [seg("Thanks for watching!"), seg("THANKS FOR WATCHING"), seg("Agenda for today")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["Agenda for today"])
    }

    @Test("keeps legitimate speech and preserves order")
    func keepsLegitSpeech() {
        let input = [seg("First point"), seg("Second point"), seg("Third point")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["First point", "Second point", "Third point"])
    }

    @Test("drops degenerate single-character repetition walls like $$$$$…")
    func dropsCharacterRunWalls() {
        let input = [
            seg(String(repeating: "$", count: 200)),
            seg(String(repeating: "-", count: 40)),
            seg("Real discussion about the roadmap"),
        ]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["Real discussion about the roadmap"])
    }

    @Test("keeps short, legitimate punctuation runs like ellipses")
    func keepsShortPunctuationRuns() {
        let input = [seg("Wait... what?"), seg("Whoa!!!"), seg("hmm---")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["Wait... what?", "Whoa!!!", "hmm---"])
    }

    @Test("drops word-repetition loops like LAUGHTER LAUGHTER LAUGHTER…")
    func dropsWordRepetitionLoops() {
        let input = [
            seg(Array(repeating: "LAUGHTER", count: 8).joined(separator: " ")),
            seg(Array(repeating: "you", count: 12).joined(separator: " ")),
            seg(Array(repeating: "thank you", count: 6).joined(separator: " ")),
            seg("And then we shipped the feature"),
        ]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["And then we shipped the feature"])
    }

    @Test("keeps short emphatic repetition like 'no no no'")
    func keepsShortEmphaticRepetition() {
        let input = [seg("no no no"), seg("yeah yeah yeah yeah"), seg("Milk coffee. Milk coffee.")]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["no no no", "yeah yeah yeah yeah", "Milk coffee. Milk coffee."])
    }

    @Test("drops common Mandarin whisper hallucinations, incl. trailing CJK punctuation")
    func dropsMandarinHallucinations() {
        let input = [
            seg("謝謝大家"),
            seg("謝謝觀看。"),
            seg("請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目"),
            seg("我們下週開會討論預算"),
        ]
        let out = HallucinationFilter.clean(input)
        #expect(out.map(\.text) == ["我們下週開會討論預算"])
    }
}
