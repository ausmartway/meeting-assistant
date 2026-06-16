import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingProcessor diarization wiring")
struct MeetingProcessorDiarizationTests {

    // A transcriber that returns one mic segment so we can observe its label.
    private struct OneMicSegmentTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?) async throws -> [TranscriptSegment] {
            channel == .microphone
                ? [TranscriptSegment(start: 0, end: 4, text: "hello from the room", channel: .microphone)]
                : []
        }
    }

    // A diarizer that splits the timeline into another speaker (not "Me").
    private struct TwoSpeakerDiarizer: Diarizing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func diarize(audioFile: URL, enrollment: MeEnrollment?, progress: TranscribeProgressHandler?) async throws -> [DiarizedSpan] {
            [DiarizedSpan(start: 0, end: 5, speakerID: "spk_a")]   // not "Me" -> Speaker 2
        }
    }

    @Test("diarized mic segments are labeled by speaker, not blanket 'Me'")
    func diarizedLabels() async throws {
        let store = try MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-diar-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: [])
        )
        try store.save(recording)
        // Create empty audio files so the path exists (transcriber is a stub).
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())

        let processor = MeetingProcessor(
            store: store,
            transcriber: OneMicSegmentTranscriber(),
            diarizer: TwoSpeakerDiarizer(),
            enrollment: nil
        )
        let transcript = try await processor.process(recording)
        #expect(transcript.contains("Speaker 2:"))
        #expect(!transcript.contains("Me:"))
    }
}
