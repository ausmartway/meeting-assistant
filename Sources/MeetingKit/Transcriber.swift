import Foundation

/// Whisper model size. All entries are **multilingual** (no `.en` variants) so
/// the recognizer can handle Mandarin as well as English with language
/// auto-detection. Larger = more accurate but slower / more memory.
/// Defaults to `.largeTurbo` — strong Mandarin accuracy, still fast on the M1
/// Pro's Neural Engine.
public enum TranscriptionModel: String, Codable, Sendable, CaseIterable {
    case small = "small"
    case medium = "medium"
    case largeTurbo = "large-v3-turbo"

    public var displayName: String {
        switch self {
        case .small: return "Small (fastest, ~0.5 GB)"
        case .medium: return "Medium (balanced, ~1.5 GB)"
        case .largeTurbo: return "Large v3 Turbo (best, multilingual, ~1.6 GB)"
        }
    }
}

/// Turns a recorded audio file into timestamped transcript segments.
///
/// This is the seam between the app and the local speech-to-text engine. The real
/// engine (WhisperKit, which runs on the Apple Neural Engine) requires the full
/// Xcode toolchain to build, so it is provided as a swap-in implementation; the
/// `StubTranscriber` keeps the whole pipeline runnable in the meantime.
public protocol Transcribing: Sendable {
    /// Transcribe one audio file. `channel` is carried through onto every segment
    /// so the speaker fuser can tell mic ("Me") from system (remote) audio.
    func transcribe(audioFile: URL, channel: AudioChannel) async throws -> [TranscriptSegment]
}

/// A no-ML placeholder so the end-to-end pipeline produces visible output before
/// WhisperKit is wired in. Emits a single segment explaining how to enable real
/// transcription rather than failing silently.
public struct StubTranscriber: Transcribing {
    public init() {}

    public func transcribe(audioFile: URL, channel: AudioChannel) async throws -> [TranscriptSegment] {
        let note = "[transcription backend not configured — open in Xcode and add WhisperKit to enable on-device speech-to-text]"
        return [TranscriptSegment(start: 0, end: 0, text: note, channel: channel)]
    }
}

// MARK: - Real engine (compiled only when WhisperKit is available)

// To enable: add WhisperKit as an SPM dependency (see Package.swift), then this
// block compiles automatically. The stub above remains the fallback.
#if canImport(WhisperKit)
import WhisperKit

public struct WhisperKitTranscriber: Transcribing {
    private let model: TranscriptionModel

    public init(model: TranscriptionModel = .largeTurbo) {
        self.model = model
    }

    public func transcribe(audioFile: URL, channel: AudioChannel) async throws -> [TranscriptSegment] {
        let pipe = try await WhisperKit(model: model.rawValue)
        // language: nil + detectLanguage: true → auto-detect per meeting
        // (handles English, Mandarin, and reasonable code-switching).
        let options = DecodingOptions(language: nil, detectLanguage: true)
        let results = try await pipe.transcribe(audioPath: audioFile.path, decodeOptions: options)
        let raw = results.flatMap { result in
            result.segments.map {
                TranscriptSegment(
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    text: $0.text.trimmingCharacters(in: .whitespaces),
                    channel: channel
                )
            }
        }
        // Drop whisper's silence hallucinations before returning.
        return HallucinationFilter.clean(raw)
    }
}
#endif
