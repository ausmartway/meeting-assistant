import Foundation

/// Chooses the concrete transcription backend, resolved inside MeetingKit where
/// the WhisperKit module is actually linked. The app target can't see that module
/// directly, so it must go through this factory rather than its own
/// `#if canImport` check (which would always be false there).
public enum Backends {

    /// The on-device transcriber: real WhisperKit when available, else the stub.
    public static func makeTranscriber(model: TranscriptionModel) -> Transcribing {
        #if canImport(WhisperKit)
        return WhisperKitTranscriber(model: model)
        #else
        return StubTranscriber()
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
}
