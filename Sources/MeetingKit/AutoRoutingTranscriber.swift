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
        // Warm only the small language detector at launch — it's always needed and
        // cheap. The big transcription model (`whisper`) and Parakeet are loaded
        // lazily on first use, so launch never compiles the ~1.6 GB model (which on
        // some setups is a multi-minute Neural-Engine compile, and on the GPU path
        // aborts entirely). A channel routed to WhisperKit (Mandarin / uncertain)
        // pays that load once, only when it actually occurs.
        if let preparable = detector as? Transcribing {
            try await preparable.prepare(progress: progress)
        }
    }

    /// Background download of everything the router might need, cheapest-first:
    /// the detector is prepared fully (small, always needed to route at all),
    /// then Parakeet (covers the common English path), then the big Whisper
    /// model — downloads only, so the multi-minute model compile stays lazy.
    /// Sequential on purpose: kinder to bandwidth, and fail-fast is fine because
    /// the lazy download-on-first-use path covers whatever is still missing.
    public func prefetch(progress: TranscribeProgressHandler?) async throws {
        if let preparable = detector as? Transcribing {
            try await preparable.prepare(progress: progress)
        }
        try await parakeet.prefetch(progress: progress)
        try await whisper.prefetch(progress: progress)
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
            return try await whisper.transcribe(
                audioFile: audioFile, channel: channel, progress: progress)
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
