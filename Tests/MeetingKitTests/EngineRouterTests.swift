import Testing
@testable import MeetingKit

@Suite("EngineRouter")
struct EngineRouterTests {

    @Test("confident English routes to Parakeet")
    func englishToParakeet() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "en", confidence: 0.95))
        #expect(r == .parakeet(languageCode: "en"))
    }

    @Test("confident Spanish (a Parakeet language) routes to Parakeet")
    func spanishToParakeet() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "es", confidence: 0.8))
        #expect(r == .parakeet(languageCode: "es"))
    }

    @Test("Mandarin routes to WhisperKit (Parakeet has no CJK)")
    func mandarinToWhisper() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "zh", confidence: 0.99))
        #expect(r == .whisperKit)
    }

    @Test("low confidence routes to WhisperKit even for English")
    func lowConfidenceToWhisper() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "en", confidence: 0.3))
        #expect(r == .whisperKit)
    }

    @Test("unknown/unsupported code routes to WhisperKit")
    func unknownToWhisper() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "ja", confidence: 0.9))
        #expect(r == .whisperKit)
    }

    @Test("nil detection routes to WhisperKit")
    func nilToWhisper() {
        let r = EngineRouter.route(detected: nil)
        #expect(r == .whisperKit)
    }

    // WhisperKit reports log-probabilities (≤ 0); a near-zero log-prob is a HIGH
    // confidence. This pins the conversion that a real bug got wrong (treating the
    // raw log-prob as a 0...1 value, so English never cleared the 0.5 threshold).
    @Test("a near-zero log-prob converts to high confidence and routes to Parakeet")
    func logProbNearZeroIsConfident() {
        let conf = EngineRouter.probability(fromLogProb: -0.08)
        #expect(conf > 0.9)
        #expect(EngineRouter.route(detected: DetectedLanguage(code: "en", confidence: conf))
                == .parakeet(languageCode: "en"))
    }

    @Test("a very negative log-prob is low confidence and routes to WhisperKit")
    func logProbVeryNegativeIsUncertain() {
        let conf = EngineRouter.probability(fromLogProb: -3.0)  // exp(-3) ≈ 0.05
        #expect(conf < 0.5)
        #expect(EngineRouter.route(detected: DetectedLanguage(code: "en", confidence: conf))
                == .whisperKit)
    }
}
