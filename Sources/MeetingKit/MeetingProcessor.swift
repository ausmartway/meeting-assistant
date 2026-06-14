import Foundation

/// Runs the heavy post-meeting pipeline from a saved `MeetingRecording`:
/// transcribe both audio channels → fuse speaker labels → render and persist the
/// transcript. This is where the GPU-bound work happens, after the call has
/// ended, so it never competes with the meeting for resources.
public final class MeetingProcessor {
    private let store: MeetingStore
    private let transcriber: Transcribing

    public init(store: MeetingStore, transcriber: Transcribing) {
        self.store = store
        self.transcriber = transcriber
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
        return transcript
    }
}
