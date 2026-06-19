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
                // Language detection uses a SMALL Whisper model, separate from the big
                // transcription model. Detection only needs the first ~30 s to identify
                // the language, so the small model is plenty — and it keeps the common
                // English path cheap: detect (small, fast) → Parakeet, never loading the
                // ~1.6 GB model. The big model is loaded lazily by `whisper` only when a
                // channel is actually routed to WhisperKit (Mandarin / uncertain).
                let whisper = WhisperKitTranscriber(model: model, concurrentWorkers: workers)
                let detector = WhisperKitTranscriber(model: .small, concurrentWorkers: workers)
                return AutoRoutingTranscriber(
                    detector: detector,
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
