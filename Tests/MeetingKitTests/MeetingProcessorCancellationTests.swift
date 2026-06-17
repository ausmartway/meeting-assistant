import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingProcessor cancellation")
struct MeetingProcessorCancellationTests {

    // A transcriber that returns promptly and ignores cancellation — simulating an
    // engine that doesn't honor cooperative cancellation. This forces the test to
    // exercise MeetingProcessor's OWN `Task.checkCancellation()` guard after the
    // transcribe step, rather than the transcriber throwing for us.
    private struct IgnoresCancellationTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?) async throws -> [TranscriptSegment] {
            channel == .microphone
                ? [TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone)]
                : []
        }
    }

    private func makeRecording() throws -> (MeetingStore, MeetingRecording) {
        let store = try MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-cancel-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: [])
        )
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        return (store, recording)
    }

    @Test("a cancelled process throws CancellationError and writes no transcript")
    func cancelStopsBeforeSave() async throws {
        let (store, recording) = try makeRecording()
        let processor = MeetingProcessor(
            store: store,
            transcriber: IgnoresCancellationTranscriber(),
            diarizer: StubDiarizer(),
            knownSpeakers: []
        )

        // Cancel immediately: transcribe still returns (it ignores cancellation),
        // but the checkpoint after it must throw before anything is persisted.
        let task = Task { try await processor.process(recording) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(store.transcript(for: recording.meeting.id) == nil)
    }
}
