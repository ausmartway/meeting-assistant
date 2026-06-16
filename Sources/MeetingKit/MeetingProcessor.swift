import Foundation
import os

/// Runs the heavy post-meeting pipeline from a saved `MeetingRecording`:
/// transcribe both audio channels → fuse speaker labels → render and persist the
/// transcript. This is where the GPU-bound work happens, after the call has
/// ended, so it never competes with the meeting for resources.
public final class MeetingProcessor {
    private let store: MeetingStore
    private let transcriber: Transcribing
    private let diarizer: Diarizing
    /// A VALUE snapshot of the known-speaker library taken at construction time —
    /// not the live, non-Sendable `SpeakerLibrary` — so background processing
    /// never races the library being edited on another thread.
    private let knownSpeakers: [KnownSpeaker]

    private static let log = Logger(subsystem: "MeetingAssistant", category: "diarization")

    public init(
        store: MeetingStore,
        transcriber: Transcribing,
        diarizer: Diarizing = StubDiarizer(),
        knownSpeakers: [KnownSpeaker] = []
    ) {
        self.store = store
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.knownSpeakers = knownSpeakers
    }

    /// Progress callback for the UI: `fraction` is 0...1 during model download
    /// (nil otherwise), `phase` is a human-readable stage label.
    public typealias ProcessProgress = @Sendable (_ fraction: Double?, _ phase: String) -> Void

    /// Process one recording end-to-end, writing `transcript.md`.
    @discardableResult
    public func process(
        _ recording: MeetingRecording,
        progress: ProcessProgress? = nil
    ) async throws -> String {
        let dir = try store.directory(for: recording.meeting.id)
        let micURL = dir.appendingPathComponent(recording.micAudioFile)
        let systemURL = dir.appendingPathComponent(recording.systemAudioFile)

        let started = Date()

        // 1. Transcribe each channel (carrying the channel through onto segments).
        //    The transcriber serializes its shared model download/load internally.
        let onProgress: TranscribeProgressHandler = { p in progress?(p.fraction, p.phase) }
        async let micSegments = transcriber.transcribe(audioFile: micURL, channel: .microphone, progress: onProgress)
        async let systemSegments = transcriber.transcribe(audioFile: systemURL, channel: .system, progress: onProgress)
        let allSegments = try await (micSegments + systemSegments)
            .sorted { $0.start < $1.start }

        // 2. Drop whisper silence artifacts.
        let cleaned = HallucinationFilter.clean(allSegments)

        // 2b. Diarize the mic channel so multiple in-room speakers are separated.
        //     Best-effort: any failure degrades to blanket "Me" (empty spans).
        var outcome = DiarizationOutcome(spans: [], embeddings: [:])
        do {
            outcome = try await diarizer.diarize(audioFile: micURL, progress: onProgress)
        } catch {
            outcome = DiarizationOutcome(spans: [], embeddings: [:])   // non-fatal — keep today's "Me" labeling
            Self.log.error("Diarization failed, falling back to single speaker: \(error.localizedDescription, privacy: .public)")
        }

        // 2c. Fuse speaker labels (mic via diarization, system via the timeline).
        //     Resolve diarized clusters to display labels against the known-speaker
        //     library snapshot; unmatched clusters fall back to anonymous
        //     "Speaker N" labels.
        let micLabels = SpeakerRecognizer.resolve(outcome: outcome, knownSpeakers: knownSpeakers)
        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: recording.timeline,
            micDiarization: outcome.spans,
            micLabels: micLabels
        )

        // 2d. Persist the per-meeting speaker map (cluster voiceprints + labels) so
        //     speakers can be renamed later without re-diarizing. Best-effort.
        if !outcome.spans.isEmpty {
            try? store.saveSpeakerMap(
                MeetingSpeakerMap(labelByCluster: micLabels, embeddingByCluster: outcome.embeddings),
                for: recording.meeting.id
            )
        }

        // 3. Render with real wall-clock timestamps (baseDate = recording start) and
        //    a note recording how long transcription took.
        let elapsed = Date().timeIntervalSince(started)
        let note = "Transcribed in \(Self.humanDuration(elapsed))"
        progress?(1.0, note)
        let transcript = TranscriptFormatter.document(
            meeting: recording.meeting,
            segments: labeled,
            baseDate: recording.recordedAt,
            note: note
        )
        try store.saveTranscript(transcript, for: recording.meeting.id)
        return transcript
    }

    /// "2m 14s" / "47s".
    static func humanDuration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}
