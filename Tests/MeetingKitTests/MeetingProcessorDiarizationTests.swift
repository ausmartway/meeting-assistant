import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingProcessor diarization wiring")
struct MeetingProcessorDiarizationTests {

    // A transcriber that returns one mic segment so we can observe its label.
    private struct OneMicSegmentTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?)
            async throws -> [TranscriptSegment]
        {
            channel == .microphone
                ? [
                    TranscriptSegment(
                        start: 0, end: 4, text: "hello from the room", channel: .microphone)
                ]
                : []
        }
    }

    // A diarizer that splits the timeline into another speaker (not "Me").
    private struct TwoSpeakerDiarizer: Diarizing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func diarize(audioFile: URL, progress: TranscribeProgressHandler?) async throws
            -> DiarizationOutcome
        {
            DiarizationOutcome(
                spans: [DiarizedSpan(start: 0, end: 5, speakerID: "spk_a")],
                embeddings: ["spk_a": [1, 0, 0]])  // not "Me" -> Speaker 2
        }
    }

    // A diarizer that always fails, to prove diarization is best-effort.
    private struct FailingDiarizer: Diarizing {
        struct Boom: Error {}
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func diarize(audioFile: URL, progress: TranscribeProgressHandler?) async throws
            -> DiarizationOutcome
        {
            throw Boom()
        }
    }

    // Records which audio files it diarized, to prove laziness; returns one cluster.
    // No lock needed: MeetingProcessor.process awaits diarize serially (mic, then
    // optionally system), never concurrently.
    private final class RecordingDiarizer: Diarizing, @unchecked Sendable {
        private(set) var files: [String] = []
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func diarize(audioFile: URL, progress: TranscribeProgressHandler?) async throws
            -> DiarizationOutcome
        {
            files.append(audioFile.lastPathComponent)
            return DiarizationOutcome(
                spans: [DiarizedSpan(start: 0, end: 5, speakerID: "spk_a")],
                embeddings: ["spk_a": [1, 0, 0]])
        }
    }

    // One mic + one system segment, so a remote (system) label can be observed.
    private struct MicAndSystemTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?)
            async throws -> [TranscriptSegment]
        {
            channel == .microphone
                ? [TranscriptSegment(start: 0, end: 4, text: "hi from me", channel: .microphone)]
                : [TranscriptSegment(start: 0, end: 4, text: "hi from room", channel: .system)]
        }
    }

    private func makeRecording(timeline: SpeakerTimeline) throws -> (MeetingStore, MeetingRecording)
    {
        let store = try MeetingStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ma-remote-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav", timeline: timeline)
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        return (store, recording)
    }

    @Test("a non-human on-screen name triggers system diarization → remote voiceprint label")
    func nonHumanNameTriggersRemoteVoiceprint() async throws {
        let timeline = SpeakerTimeline(samples: [
            SpeakerSample(timestamp: 0, speakerName: "Boardroom")
        ])
        let (store, recording) = try makeRecording(timeline: timeline)
        let diarizer = RecordingDiarizer()
        let processor = MeetingProcessor(
            store: store, transcriber: MicAndSystemTranscriber(), diarizer: diarizer,
            knownSpeakers: [])
        let transcript = try await processor.process(recording)
        #expect(diarizer.files.contains("sys.wav"))  // system channel WAS diarized
        #expect(transcript.contains("Speaker 3:"))  // remote voiceprint (mic used Speaker 2)
        #expect(!transcript.contains("Boardroom"))  // room name not used as a speaker
    }

    @Test("all-human on-screen names skip system diarization")
    func humanNamesSkipRemoteDiarization() async throws {
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Alice")])
        let (store, recording) = try makeRecording(timeline: timeline)
        let diarizer = RecordingDiarizer()
        let processor = MeetingProcessor(
            store: store, transcriber: MicAndSystemTranscriber(), diarizer: diarizer,
            knownSpeakers: [])
        let transcript = try await processor.process(recording)
        #expect(diarizer.files.contains("mic.wav"))  // mic always diarized
        #expect(!diarizer.files.contains("sys.wav"))  // system NOT diarized (lazy)
        #expect(transcript.contains("Alice:"))  // human on-screen name used
    }

    private func makeRecording() throws -> (MeetingStore, MeetingRecording) {
        let store = try MeetingStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ma-diar-\(UUID().uuidString)"))
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

    @Test("diarized mic segments are labeled by speaker, not blanket 'Me'")
    func diarizedLabels() async throws {
        let (store, recording) = try makeRecording()
        let processor = MeetingProcessor(
            store: store,
            transcriber: OneMicSegmentTranscriber(),
            diarizer: TwoSpeakerDiarizer(),
            knownSpeakers: []
        )
        let transcript = try await processor.process(recording)
        #expect(transcript.contains("Speaker 2:"))
        #expect(!transcript.contains("Me:"))
    }

    @Test("a failing diarizer is non-fatal: processing succeeds and mic stays 'Me'")
    func diarizationFailureFallsBackToMe() async throws {
        let (store, recording) = try makeRecording()
        let processor = MeetingProcessor(
            store: store,
            transcriber: OneMicSegmentTranscriber(),
            diarizer: FailingDiarizer(),
            knownSpeakers: []
        )
        let transcript = try await processor.process(recording)
        #expect(transcript.contains("Me:"))
        #expect(!transcript.contains("Speaker 2:"))
    }

    @Test("processing persists the per-meeting speaker map")
    func persistsSpeakerMap() async throws {
        let (store, recording) = try makeRecording()
        let processor = MeetingProcessor(
            store: store,
            transcriber: OneMicSegmentTranscriber(),
            diarizer: TwoSpeakerDiarizer(),
            knownSpeakers: []
        )
        _ = try await processor.process(recording)
        let map = store.speakerMap(for: recording.meeting.id)
        #expect(map?.labelByCluster["spk_a"] == "Speaker 2")
        #expect(map?.embeddingByCluster["spk_a"] == [1, 0, 0])
    }

    @Test("MeetingSpeakerMap round-trips through the store")
    func speakerMapRoundTrips() async throws {
        let (store, recording) = try makeRecording()
        let map = MeetingSpeakerMap(
            labelByCluster: ["spk_a": "Alice", "spk_b": "Speaker 2"],
            embeddingByCluster: ["spk_a": [0.1, 0.2, 0.3], "spk_b": [1, 0, 0]]
        )
        try store.saveSpeakerMap(map, for: recording.meeting.id)
        let back = store.speakerMap(for: recording.meeting.id)
        #expect(back == map)
    }

    @Test("re-processing deletes the prior per-meeting speaker map")
    func reprocessResetsSpeakerMap() async throws {
        let store = try MeetingStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ma-reproc-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: []))
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        try store.saveSpeakerMap(
            MeetingSpeakerMap(
                labelByCluster: ["S1": "Larry Song"], embeddingByCluster: ["S1": [1]]),
            for: meeting.id)

        let processor = MeetingProcessor(
            store: store, transcriber: StubTranscriber(), diarizer: StubDiarizer(),
            knownSpeakers: [], localUserName: "Yulei Liu")
        _ = try await processor.process(recording)

        #expect(store.speakerMap(for: meeting.id) == nil)
    }
}
