import Testing

@testable import MeetingKit

@Suite("HumanNameClassifier.isHumanName")
struct HumanNameClassifierTests {

    @Test("confident human names are human")
    func humanNames() {
        #expect(HumanNameClassifier.isHumanName("John Smith"))
        #expect(HumanNameClassifier.isHumanName("Mei Chen"))
        #expect(HumanNameClassifier.isHumanName("李伟"))
        #expect(HumanNameClassifier.isHumanName("Alice"))
    }

    @Test("hyphenated and apostrophe human names are human")
    func punctuatedHumanNames() {
        #expect(HumanNameClassifier.isHumanName("Mary-Jane Smith"))
        #expect(HumanNameClassifier.isHumanName("O'Brien"))
        #expect(HumanNameClassifier.isHumanName("Anne-Marie"))
    }

    @Test("human names containing device-word letters survive (whole-token matching)")
    func deviceLettersInNameSurvive() {
        #expect(HumanNameClassifier.isHumanName("Owen Taplin"))  // contains 'tap', 'owl'-ish letters
    }

    @Test("room and device names are not human")
    func roomAndDevice() {
        #expect(!HumanNameClassifier.isHumanName("Boardroom"))
        #expect(!HumanNameClassifier.isHumanName("Meeting Room 3"))
        #expect(!HumanNameClassifier.isHumanName("Poly Studio X50"))
        #expect(!HumanNameClassifier.isHumanName("会议室 A"))
        #expect(!HumanNameClassifier.isHumanName("Conference Room"))
    }

    @Test("ambiguous strings default to not-human (use voiceprints)")
    func ambiguousDefaultsToNonHuman() {
        #expect(!HumanNameClassifier.isHumanName("guest"))  // lowercase
        #expect(!HumanNameClassifier.isHumanName("x"))  // too short / lowercase
        #expect(!HumanNameClassifier.isHumanName("🎤"))  // not a name
        #expect(!HumanNameClassifier.isHumanName("a b c d e"))  // too many tokens
        #expect(!HumanNameClassifier.isHumanName(""))  // empty
        #expect(!HumanNameClassifier.isHumanName("MTR204"))  // all-caps + digit device id
    }
}
