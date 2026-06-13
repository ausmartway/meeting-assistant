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

    /// Process one recording end-to-end, writing `transcript.md` and `summary.md`.
    @discardableResult
    public func process(_ recording: MeetingRecording) async throws -> (transcript: String, summary: MeetingSummary) {
        let dir = try store.directory(for: recording.meeting.id)
        let micURL = dir.appendingPathComponent(recording.micAudioFile)
        let systemURL = dir.appendingPathComponent(recording.systemAudioFile)

        // 1. Transcribe each channel (carrying the channel through onto segments).
        async let micSegments = transcriber.transcribe(audioFile: micURL, channel: .microphone)
        async let systemSegments = transcriber.transcribe(audioFile: systemURL, channel: .system)
        let allSegments = try await (micSegments + systemSegments)
            .sorted { $0.start < $1.start }

        // 2. Drop whisper silence artifacts, then fuse speaker labels.
        let cleaned = HallucinationFilter.clean(allSegments)
        let labeled = SpeakerFuser.fuse(segments: cleaned, timeline: recording.timeline)

        // 3. Render and persist the transcript.
        let transcript = TranscriptFormatter.document(meeting: recording.meeting, segments: labeled)
        try store.saveTranscript(transcript, for: recording.meeting.id)

        // 4. Summarize and persist.
        let body = TranscriptFormatter.transcriptBody(labeled)
        let summary = try await summarizer.summarize(transcript: body, meetingTitle: recording.meeting.title)
        try store.saveSummary(summary.markdown(), for: recording.meeting.id)

        return (transcript, summary)
    }
}
