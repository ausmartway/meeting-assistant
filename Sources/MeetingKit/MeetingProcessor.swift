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
    /// Display name for the local user's mic segments (defaults to the generic "Me").
    private let localUserName: String

    private static let log = Logger(subsystem: "MeetingAssistant", category: "diarization")

    public init(
        store: MeetingStore,
        transcriber: Transcribing,
        diarizer: Diarizing = StubDiarizer(),
        knownSpeakers: [KnownSpeaker] = [],
        localUserName: String = "Me"
    ) {
        self.store = store
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.knownSpeakers = knownSpeakers
        self.localUserName = localUserName
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

        // Re-transcription must re-recognize from scratch: drop the previous
        // per-meeting speaker map so stale labels don't carry over.
        store.deleteSpeakerMap(for: recording.meeting.id)

        let started = Date()

        // 1. Transcribe each channel (carrying the channel through onto segments),
        //    one channel at a time. Running both channels concurrently doubled the
        //    peak number of in-flight CoreML/Metal predictions (each channel already
        //    decodes VAD chunks in parallel), which under GPU/memory pressure could
        //    trip an MPSGraph assertion that aborts the app. Post-meeting processing
        //    is the cheap-to-be-slow path, so we serialize the channels for stability.
        let onProgress: TranscribeProgressHandler = { p in progress?(p.fraction, p.phase) }
        let micSegments = try await transcriber.transcribe(
            audioFile: micURL, channel: .microphone, progress: onProgress)
        try Task.checkCancellation()
        let systemSegments = try await transcriber.transcribe(
            audioFile: systemURL, channel: .system, progress: onProgress)
        let allSegments = (micSegments + systemSegments)
            .sorted { $0.start < $1.start }

        // The user may have stopped this transcript while the (cancellation-
        // cooperative) transcribe step ran. Bail before the expensive diarize/fuse/
        // save so nothing partial is written — the recording stays re-transcribable.
        try Task.checkCancellation()

        // 2. Drop whisper silence artifacts.
        let cleaned = HallucinationFilter.clean(allSegments)

        // 2b. Diarize the mic channel so multiple in-room speakers are separated.
        //     Best-effort: any failure degrades to blanket "Me" (empty spans).
        var outcome = DiarizationOutcome(spans: [], embeddings: [:])
        do {
            outcome = try await diarizer.diarize(audioFile: micURL, progress: onProgress)
        } catch {
            outcome = DiarizationOutcome(spans: [], embeddings: [:])  // non-fatal — keep today's "Me" labeling
            Self.log.error(
                "Diarization failed, falling back to single speaker: \(error.localizedDescription, privacy: .public)"
            )
        }

        // Second checkpoint: stop before fusing/formatting/saving if cancelled
        // during diarization.
        try Task.checkCancellation()

        // 2c. Fuse speaker labels (mic via diarization, system via the timeline).
        //     Resolve diarized clusters to display labels against the known-speaker
        //     library snapshot; unmatched clusters fall back to anonymous
        //     "Speaker N" labels.
        let micLabels = SpeakerRecognizer.resolve(outcome: outcome, knownSpeakers: knownSpeakers)
        // Multi-frame voting cleans OCR misreads/variants before fusion (post-processing).
        let consolidatedTimeline = SpeakerTimelineConsolidator.consolidate(recording.timeline)

        // 2c-remote. When a remote speaker's on-screen name isn't confidently a human
        // name (a shared room/device endpoint), identify remote speakers by voiceprint:
        // diarize the system channel and resolve its clusters. Lazy — skipped entirely
        // when every remote name is a confident human name.
        var systemOutcome = DiarizationOutcome(spans: [], embeddings: [:])
        var systemLabels: [String: String] = [:]
        if needsRemoteDiarization(segments: cleaned, timeline: consolidatedTimeline) {
            do {
                systemOutcome = try await diarizer.diarize(
                    audioFile: systemURL, progress: onProgress)
                try Task.checkCancellation()
                let micAnon = micLabels.values.filter { $0.hasPrefix("Speaker ") }.count
                systemLabels = SpeakerRecognizer.resolve(
                    outcome: systemOutcome, knownSpeakers: knownSpeakers,
                    startingAnon: 2 + micAnon)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.error(
                    "System diarization failed; remote speakers stay anonymous: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: consolidatedTimeline,
            micDiarization: outcome.spans,
            micLabels: micLabels,
            systemDiarization: systemOutcome.spans,
            systemLabels: systemLabels,
            micLabel: localUserName
        )

        // 2d. Persist the merged per-meeting speaker map so any speaker (local or
        //     remote) can be renamed later without re-diarizing. System cluster ids
        //     are namespaced ("sys:") so they can't collide with mic cluster ids;
        //     labels are already unique via the shared "Speaker N" numbering.
        var mapLabels = micLabels
        var mapEmbeddings = outcome.embeddings
        var mapDurations = SpeakerRecognizer.speechDuration(byCluster: outcome.spans)
        for (cluster, label) in systemLabels { mapLabels["sys:\(cluster)"] = label }
        for (cluster, emb) in systemOutcome.embeddings { mapEmbeddings["sys:\(cluster)"] = emb }
        for (cluster, dur) in SpeakerRecognizer.speechDuration(byCluster: systemOutcome.spans) {
            mapDurations["sys:\(cluster)"] = dur
        }
        if !mapLabels.isEmpty {
            try? store.saveSpeakerMap(
                MeetingSpeakerMap(
                    labelByCluster: mapLabels, embeddingByCluster: mapEmbeddings,
                    durationByCluster: mapDurations),
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
        // Persist the fused segments so each transcript line can be played back
        // (speaker verification). Best-effort: a failure only disables playback.
        try? store.saveSegments(labeled, for: recording.meeting.id)
        return transcript
    }

    /// True if any remote (system) segment's on-screen active-speaker name is not
    /// confidently a human name — meaning we should identify remote speakers by
    /// voiceprint instead. Uses the (already consolidated) OCR timeline.
    private func needsRemoteDiarization(
        segments: [TranscriptSegment], timeline: SpeakerTimeline
    ) -> Bool {
        for seg in segments where seg.channel == .system {
            let midpoint = (seg.start + seg.end) / 2
            if let name = SpeakerFuser.activeSpeaker(at: midpoint, in: timeline),
                !HumanNameClassifier.isHumanName(name)
            {
                return true
            }
        }
        return false
    }

    /// "2m 14s" / "47s".
    static func humanDuration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}
