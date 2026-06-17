import Foundation

/// The language detected for a piece of audio, with the detector's confidence.
public struct DetectedLanguage: Sendable, Equatable {
    public let code: String        // ISO-ish code, e.g. "en", "zh", "es"
    public let confidence: Double  // 0...1
    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }
}

/// Detects the spoken language of an audio file (a cheap pass, not a full
/// transcription). Implemented by the WhisperKit backend, which loads the
/// multilingual model anyway.
public protocol LanguageDetecting: Sendable {
    /// Returns the detected language, or nil when it can't decide.
    func detectLanguage(audioFile: URL) async throws -> DetectedLanguage?
}

/// Which engine a channel should use, decided from its detected language.
public enum RoutedEngine: Sendable, Equatable {
    case whisperKit
    case parakeet(languageCode: String)
}

/// Pure routing policy for the `auto` engine: send confidently-detected
/// English/European audio to fast Parakeet (which can take a language hint), and
/// everything else — CJK, unknown scripts, or low-confidence — to WhisperKit.
public enum EngineRouter {
    /// Languages Parakeet `.v3` supports (mirrors FluidAudio's `Language` enum).
    /// Deliberately has NO CJK — Parakeet produces gibberish on Mandarin.
    public static let parakeetLanguages: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "ro", "nl", "da", "sv", "fi", "hu",
        "et", "lv", "lt", "mt", "pl", "cs", "sk", "sl", "hr", "bs", "ru", "uk",
        "be", "bg", "sr", "el",
    ]

    public static func route(
        detected: DetectedLanguage?,
        threshold: Double = 0.5
    ) -> RoutedEngine {
        guard let d = detected,
              d.confidence >= threshold,
              parakeetLanguages.contains(d.code) else {
            return .whisperKit
        }
        return .parakeet(languageCode: d.code)
    }
}
