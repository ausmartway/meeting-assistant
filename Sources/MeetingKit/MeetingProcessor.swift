import Foundation

/// Runs the heavy post-meeting pipeline from a saved `MeetingRecording`:
/// transcribe both audio channels → fuse speaker labels → render the transcript
/// → summarize → persist. This is where the GPU-bound work happens, after the
/// call has ended, so it never competes with the meeting for resources.
public final class MeetingProcessor {
    private let store: MeetingStore
    private let transcriber: Transcribing
    private let summarizer: Summarizing

    public init(store: MeetingStore, transcriber: Transcribing, summarizer: Summarizing) {
        self.store = store
        self.transcriber = transcriber
        self.summarizer = summarizer
    }

    /// Progress callback for the UI: `fraction` is 0...1 during model download
    /// (nil otherwise), `phase` is a human-readable stage label.
    public typealias ProcessProgress = @Sendable (_ fraction: Double?, _ phase: String) -> Void

    /// Process one recording end-to-end, writing `transcript.md` and `summary.md`.
    @discardableResult
    public func process(
        _ recording: MeetingRecording,
        progress: ProcessProgress? = nil
    ) async throws -> (transcript: String, summary: MeetingSummary) {
        let dir = try store.directory(for: recording.meeting.id)
        let micURL = dir.appendingPathComponent(recording.micAudioFile)
        let systemURL = dir.appendingPathComponent(recording.systemAudioFile)

        // 1. Transcribe each channel (carrying the channel through onto segments).
        //    The transcriber serializes its shared model download/load internally.
        let onProgress: TranscribeProgressHandler = { p in progress?(p.fraction, p.phase) }
        async let micSegments = transcriber.transcribe(audioFile: micURL, channel: .microphone, progress: onProgress)
        async let systemSegments = transcriber.transcribe(audioFile: systemURL, channel: .system, progress: onProgress)
        let allSegments = try await (micSegments + systemSegments)
            .sorted { $0.start < $1.start }

        // 2. Drop whisper silence artifacts, then fuse speaker labels.
        let cleaned = HallucinationFilter.clean(allSegments)
        let labeled = SpeakerFuser.fuse(segments: cleaned, timeline: recording.timeline)

        // 3. Render and persist the transcript.
        let transcript = TranscriptFormatter.document(meeting: recording.meeting, segments: labeled)
        try store.saveTranscript(transcript, for: recording.meeting.id)

        // 4. Summarize and persist.
        progress?(nil, "Summarizing…")
        let body = TranscriptFormatter.transcriptBody(labeled)
        let summary = try await summarizer.summarize(transcript: body, meetingTitle: recording.meeting.title)
        try store.saveSummary(summary.markdown(), for: recording.meeting.id)

        return (transcript, summary)
    }
}
