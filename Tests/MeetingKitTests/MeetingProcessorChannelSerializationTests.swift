import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingProcessor channel serialization")
struct MeetingProcessorChannelSerializationTests {

    /// Tracks how many `transcribe` calls are in flight at once. With a suspension
    /// point between enter and exit, two concurrently-launched channel transcriptions
    /// would both `enter` before either `exit`s (maxActive == 2); strictly sequential
    /// transcription never exceeds one in flight (maxActive == 1).
    private actor ConcurrencyProbe {
        private(set) var maxActive = 0
        private var active = 0
        func enter() {
            active += 1
            maxActive = max(maxActive, active)
        }
        func exit() { active -= 1 }
    }

    private struct ProbeTranscriber: Transcribing {
        let probe: ConcurrencyProbe
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(
            audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?
        ) async throws -> [TranscriptSegment] {
            await probe.enter()
            await Task.yield()  // let any concurrent sibling run before we exit
            await probe.exit()
            return []
        }
    }

    private func makeRecording() throws -> (MeetingStore, MeetingRecording) {
        let store = try MeetingStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ma-serial-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: [])
        )
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        return (store, recording)
    }

    @Test("mic and system channels are transcribed one at a time, not concurrently")
    func channelsAreSerialized() async throws {
        let (store, recording) = try makeRecording()
        let probe = ConcurrencyProbe()
        let processor = MeetingProcessor(
            store: store,
            transcriber: ProbeTranscriber(probe: probe),
            diarizer: StubDiarizer(),
            knownSpeakers: []
        )
        _ = try await processor.process(recording)
        #expect(await probe.maxActive == 1)
    }
}
