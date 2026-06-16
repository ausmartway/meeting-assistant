import Testing
@testable import MeetingKit

@Suite("VoiceMatch")
struct VoiceMatchTests {
    @Test("identical vectors have distance 0")
    func identical() {
        #expect(VoiceMatch.cosineDistance([1, 0, 1], [1, 0, 1]) == 0)
    }
    @Test("orthogonal vectors have distance 1")
    func orthogonal() {
        #expect(abs(VoiceMatch.cosineDistance([1, 0], [0, 1]) - 1) < 1e-6)
    }
    @Test("closer vectors have smaller distance than farther ones")
    func ordering() {
        let near = VoiceMatch.cosineDistance([1, 1, 0], [1, 0.9, 0])
        let far  = VoiceMatch.cosineDistance([1, 1, 0], [0, 0, 1])
        #expect(near < far)
    }
    @Test("empty or zero-magnitude vectors return infinity (no match)")
    func degenerate() {
        #expect(VoiceMatch.cosineDistance([], []) == .infinity)
        #expect(VoiceMatch.cosineDistance([0, 0], [1, 1]) == .infinity)
    }
    @Test("mismatched non-empty lengths return infinity (no match)")
    func lengthMismatch() {
        #expect(VoiceMatch.cosineDistance([1, 0], [1, 0, 0]) == .infinity)
    }
}
