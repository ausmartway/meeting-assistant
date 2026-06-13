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
}
