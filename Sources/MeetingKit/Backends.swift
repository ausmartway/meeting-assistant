import Foundation

/// Chooses the concrete transcription backend, resolved inside MeetingKit where
/// the WhisperKit module is actually linked. The app target can't see that module
/// directly, so it must go through this factory rather than its own
/// `#if canImport` check (which would always be false there).
public enum Backends {

    /// The on-device transcriber: real WhisperKit when available, else the stub.
    /// `workers` is the VAD decode parallelism (see `WhisperKitTranscriber`).
    public static func makeTranscriber(
        engine: TranscriptionEngine = .whisperKit,
        model: TranscriptionModel,
        workers: Int = 4
    ) -> Transcribing {
        switch engine {
        case .parakeet:
            #if canImport(FluidAudio)
            return FluidAudioTranscriber()
            #else
            return StubTranscriber()
            #endif
        case .auto:
            #if canImport(WhisperKit) && canImport(FluidAudio)
            let whisper = WhisperKitTranscriber(model: model, concurrentWorkers: workers)
            return AutoRoutingTranscriber(
                detector: whisper,
                whisper: whisper,
                parakeet: FluidAudioTranscriber(version: .v3)
            )
            #elseif canImport(WhisperKit)
            return WhisperKitTranscriber(model: model, concurrentWorkers: workers)
            #else
            return StubTranscriber()
            #endif
        case .whisperKit:
            #if canImport(WhisperKit)
            return WhisperKitTranscriber(model: model, concurrentWorkers: workers)
            #else
            return StubTranscriber()
            #endif
        }
    }

    /// Whether a real on-device transcription backend is compiled in.
    public static var hasLocalTranscription: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    /// A language detector (WhisperKit) for diagnostics / the auto engine, or nil
    /// when no real backend is compiled in.
    public static func makeLanguageDetector() -> LanguageDetecting? {
        #if canImport(WhisperKit)
        return WhisperKitTranscriber()
        #else
        return nil
        #endif
    }

    /// The on-device diarizer: real FluidAudio when available, else the stub.
    public static func makeDiarizer() -> Diarizing {
        #if canImport(FluidAudio)
        return FluidAudioDiarizer()
        #else
        return StubDiarizer()
        #endif
    }

    /// Whether a real on-device diarization backend is compiled in.
    public static var hasLocalDiarization: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }
}
