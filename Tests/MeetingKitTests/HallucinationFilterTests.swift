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
