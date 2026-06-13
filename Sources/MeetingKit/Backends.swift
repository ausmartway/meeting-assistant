import Foundation

/// Chooses the concrete ML backends, resolved inside MeetingKit where the
/// WhisperKit / MLX modules are actually linked. The app target can't see those
/// modules directly, so it must go through these factories rather than its own
/// `#if canImport` checks (which would always be false there).
public enum Backends {

    /// The on-device transcriber: real WhisperKit when available, else the stub.
    public static func makeTranscriber(model: TranscriptionModel) -> Transcribing {
        #if canImport(WhisperKit)
        return WhisperKitTranscriber(model: model)
        #else
        return StubTranscriber()
        #endif
    }

    /// The local (private) summarizer: real MLX LLM when available, else the stub.
    public static func makeLocalSummarizer() -> Summarizing {
        #if canImport(MLXLLM)
        return MLXSummarizer()
        #else
        return StubSummarizer()
        #endif
    }

    /// Whether a real on-device transcription backend is compiled in.
    public static var hasLocalTranscription: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    /// Whether a real local summarization backend is compiled in.
    public static var hasLocalSummarization: Bool {
        #if canImport(MLXLLM)
        return true
        #else
        return false
        #endif
    }
}
