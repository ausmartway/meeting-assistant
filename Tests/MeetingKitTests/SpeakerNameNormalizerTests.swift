import Testing

@testable import MeetingKit

@Suite("SpeakerNameNormalizer.displayName")
struct SpeakerNameNormalizerDisplayNameTests {

    @Test("trims and collapses internal whitespace")
    func collapsesWhitespace() {
        #expect(SpeakerNameNormalizer.displayName("  John   Smith ") == "John Smith")
    }

    @Test("strips trailing English role markers, case-insensitively")
    func stripsEnglishRoles() {
        #expect(SpeakerNameNormalizer.displayName("John Smith (Host)") == "John Smith")
        #expect(SpeakerNameNormalizer.displayName("Jane Doe (You)") == "Jane Doe")
        #expect(SpeakerNameNormalizer.displayName("Sam (co-host)") == "Sam")
        #expect(SpeakerNameNormalizer.displayName("Pat (Guest)") == "Pat")
    }

    @Test("strips trailing Chinese role markers")
    func stripsChineseRoles() {
        #expect(SpeakerNameNormalizer.displayName("王伟（主持人）") == "王伟")
    }

    @Test("returns nil for empty or too-short results")
    func nilForEmpty() {
        #expect(SpeakerNameNormalizer.displayName("") == nil)
        #expect(SpeakerNameNormalizer.displayName("   ") == nil)
        #expect(SpeakerNameNormalizer.displayName("(Host)") == nil)
        #expect(SpeakerNameNormalizer.displayName("A") == nil)
    }

    @Test("leaves a clean name untouched")
    func leavesCleanName() {
        #expect(SpeakerNameNormalizer.displayName("Mei Chen") == "Mei Chen")
    }
}
