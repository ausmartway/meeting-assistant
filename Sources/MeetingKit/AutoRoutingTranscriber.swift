import Foundation

/// The `auto` engine: detects each channel's language and routes it to the right
/// backend — fast Parakeet for English/European, WhisperKit for Mandarin/other or
/// when detection is uncertain. Routing is per channel, so a bilingual meeting
/// (English mic, Mandarin system) is handled correctly. Output is identical in
/// shape to either engine (channel-tagged, timestamped segments), so SpeakerFuser
/// and the mic/system split are unaffected.
public actor AutoRoutingTranscriber: Transcribing {
    private let detector: LanguageDetecting
    private let whisper: Transcribing
    private let parakeet: Transcribing
    /// Prepare Parakeet lazily — an all-Mandarin user never pays its download/load.
    private var parakeetPrepared = false

    public init(detector: LanguageDetecting, whisper: Transcribing, parakeet: Transcribing) {
        self.detector = detector
        self.whisper = whisper
        self.parakeet = parakeet
    }

    public func prepare(progress: TranscribeProgressHandler?) async throws {
        // The detector (WhisperKit) is always needed — for detection and for any
        // non-Parakeet channel. Parakeet is prepared on first use.
        try await whisper.prepare(progress: progress)
    }

    public func setConcurrentWorkers(_ count: Int) async {
        await whisper.setConcurrentWorkers(count)
    }

    public func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        let detected = try? await detector.detectLanguage(audioFile: audioFile)
        switch EngineRouter.route(detected: detected) {
        case .whisperKit:
            return try await whisper.transcribe(audioFile: audioFile, channel: channel, progress: progress)
        case .parakeet(let code):
            if !parakeetPrepared {
                try await parakeet.prepare(progress: progress)
                parakeetPrepared = true
            }
            return try await parakeet.transcribe(
                audioFile: audioFile, channel: channel, languageHint: code, progress: progress
            )
        }
    }
}
