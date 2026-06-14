import Testing
@testable import MeetingKit

@Suite("WhisperTextCleaner")
struct WhisperTextCleanerTests {

    @Test("strips special + timestamp tokens, keeping the spoken text")
    func stripsTokens() {
        let raw = "<|startoftranscript|><|zh|><|transcribe|><|0.00|>什么玩意儿<|28.62|>"
        #expect(WhisperTextCleaner.clean(raw) == "什么玩意儿")
    }

    @Test("collapses whitespace left where tokens were removed")
    func collapsesWhitespace() {
        let raw = "<|10.60|>说话<|11.60|> <|22.40|>说话嘛<|23.00|>"
        #expect(WhisperTextCleaner.clean(raw) == "说话 说话嘛")
    }

    @Test("leaves clean English text untouched")
    func leavesCleanText() {
        #expect(WhisperTextCleaner.clean("Hello everyone") == "Hello everyone")
    }

    @Test("returns empty for a tokens-only fragment")
    func tokensOnly() {
        #expect(WhisperTextCleaner.clean("<|startoftranscript|><|0.00|><|5.00|>") == "")
    }
}
