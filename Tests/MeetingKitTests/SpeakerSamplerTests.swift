import Testing
@testable import MeetingKit

@Suite("SpeakerSampler.bestName")
struct SpeakerSamplerTests {

    @Test("prefers a full name over UI control words")
    func prefersNameOverControls() {
        let lines = ["Mute", "Alice Johnson", "Stop Video"]
        #expect(SpeakerSampler.bestName(from: lines) == "Alice Johnson")
    }

    @Test("rejects lines that are mostly non-letters")
    func rejectsNonLetterLines() {
        let lines = ["12:34", "98%", "----"]
        #expect(SpeakerSampler.bestName(from: lines) == nil)
    }

    @Test("filters out the 'You' self-label")
    func filtersYou() {
        let lines = ["You"]
        #expect(SpeakerSampler.bestName(from: lines) == nil)
    }

    @Test("returns nil for empty input")
    func emptyInput() {
        #expect(SpeakerSampler.bestName(from: []) == nil)
    }

    @Test("picks a Chinese name over Chinese UI control words")
    func picksChineseName() {
        let lines = ["静音", "王伟", "停止视频"]
        #expect(SpeakerSampler.bestName(from: lines) == "王伟")
    }
}
