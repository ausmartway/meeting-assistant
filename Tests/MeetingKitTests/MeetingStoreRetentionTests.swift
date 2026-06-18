import Testing
import Foundation
@testable import MeetingKit

@Suite struct MeetingStoreRetentionTests {
    // Build a store rooted in a fresh temp dir.
    func makeStore() throws -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-retention-\(UUID().uuidString)", isDirectory: true)
        return (try MeetingStore(root: root), root)
    }

    // Write a full bundle (recording.json + both WAVs + transcript) for a meeting
    // recorded `recordedAt`.
    @discardableResult
    func seed(_ store: MeetingStore, id: String, recordedAt: Date,
              micBytes: Int = 1_000, systemBytes: Int = 2_000) throws -> URL {
        let dir = try store.directory(for: id)
        let meeting = Meeting(id: id, title: "M", startDate: recordedAt, endDate: recordedAt,
                              provider: nil, joinURL: nil)
        try store.save(MeetingRecording(meeting: meeting, recordedAt: recordedAt,
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: [])))
        try store.saveTranscript("# M\n\ntranscript", for: id)
        try Data(count: micBytes).write(to: dir.appendingPathComponent("mic.wav"))
        try Data(count: systemBytes).write(to: dir.appendingPathComponent("system.wav"))
        return dir
    }

    @Test func hasAudioReflectsWavPresence() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "a", recordedAt: Date())
        #expect(store.hasAudio(meetingID: "a") == true)
        store.expireMedia(meetingID: "a")
        #expect(store.hasAudio(meetingID: "a") == false)
    }

    @Test func expireMediaDeletesOnlyWavsKeepsTranscript() throws {
        let (store, _) = try makeStore()
        let dir = try seed(store, id: "a", recordedAt: Date())
        store.expireMedia(meetingID: "a")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path) == true)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("recording.json").path) == true)
        #expect(store.transcript(for: "a") == "# M\n\ntranscript")
    }

    @Test func expireMediaIsIdempotent() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "a", recordedAt: Date())
        store.expireMedia(meetingID: "a")
        store.expireMedia(meetingID: "a") // must not throw or crash
        #expect(store.hasAudio(meetingID: "a") == false)
    }

    @Test func totalSizeCountsAllBundles() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "a", recordedAt: Date(), micBytes: 1_000, systemBytes: 2_000)
        try seed(store, id: "b", recordedAt: Date(), micBytes: 500, systemBytes: 500)
        // Both WAV sets (3_000 + 1_000) plus small json/md overhead.
        #expect(store.totalSize() >= 4_000)
    }
}
