import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingStore")
struct MeetingStoreTests {

    /// A store rooted in a fresh temp directory, isolated per test.
    private func makeStore() throws -> (MeetingStore, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (try MeetingStore(root: tmp), tmp)
    }

    private func recording(id: String) -> MeetingRecording {
        MeetingRecording(
            meeting: Meeting.adHoc(id: id, provider: nil, start: Date(timeIntervalSince1970: 0)),
            recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav",
            systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: [])
        )
    }

    @Test("totalSize excludes the downloaded model caches")
    func totalSizeExcludesModels() throws {
        let (store, root) = try makeStore()
        try store.save(recording(id: "m1"))
        try store.saveTranscript("# Hi there, this is a transcript", for: "m1")
        let bundleOnly = store.totalSize()
        #expect(bundleOnly > 0)

        // Large model caches sit alongside the meeting bundles under the root; they
        // must NOT count toward the user-facing "space used" total.
        for modelDir in ["WhisperModels", "DiarizationModels"] {
            let dir = root.appendingPathComponent(modelDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 5_000_000).write(to: dir.appendingPathComponent("model.bin"))
        }
        #expect(store.totalSize() == bundleOnly)
    }

    @Test("delete removes the meeting bundle and drops it from the listing")
    func deleteRemovesBundle() throws {
        let (store, _) = try makeStore()
        try store.save(recording(id: "meeting-1"))
        try store.save(recording(id: "meeting-2"))
        try store.saveTranscript("# Hi", for: "meeting-1")
        #expect(store.allRecordings().count == 2)

        try store.delete(meetingID: "meeting-1")

        let remaining = store.allRecordings()
        #expect(remaining.count == 1)
        #expect(remaining.first?.meeting.id == "meeting-2")
        #expect(store.transcript(for: "meeting-1") == nil)
    }

    @Test("deleting a meeting that doesn't exist is a no-op, not an error")
    func deleteMissingIsNoOp() throws {
        let (store, _) = try makeStore()
        try store.delete(meetingID: "never-existed")  // must not throw
        #expect(store.allRecordings().isEmpty)
    }

    @Test("transcriptURL points at the transcript file inside the meeting bundle")
    func transcriptURLLocation() throws {
        let (store, _) = try makeStore()
        try store.saveTranscript("# Notes", for: "meeting-x")
        let url = store.transcriptURL(for: "meeting-x")
        #expect(url.lastPathComponent == "transcript.md")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
