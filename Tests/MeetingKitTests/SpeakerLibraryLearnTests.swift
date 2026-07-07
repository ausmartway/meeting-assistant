import Foundation
import Testing

@testable import MeetingKit

@Suite("SpeakerLibrary.learn")
struct SpeakerLibraryLearnTests {
    private func makeLibrary() throws -> (SpeakerLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("learn-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("speakers.json")
        return (SpeakerLibrary(url: url), url)
    }

    @Test("learn appends a sample to an existing speaker (case-insensitive)")
    func learnAppends() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.learn(name: "sam", embedding: [0, 1, 0], seconds: 120)
        let sam = lib.all().first { $0.name == "Sam" }
        #expect(sam?.samples.count == 2)
        #expect(sam?.samples.last?.seconds == 120)
        #expect(sam?.isMe == false)
    }

    @Test("learn creates a new speaker when the name is unknown")
    func learnCreates() throws {
        let (lib, _) = try makeLibrary()
        try lib.learn(name: "New Person", embedding: [0, 1, 0], seconds: 60)
        #expect(lib.all().first?.name == "New Person")
        #expect(lib.all().first?.samples.count == 1)
    }

    @Test("learn never flips isMe on an existing speaker")
    func learnPreservesIsMe() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Yulei", embedding: [1, 0, 0], isMe: true)
        try lib.learn(name: "Yulei", embedding: [0, 1, 0], seconds: 60, isMe: false)
        #expect(lib.me?.name == "Yulei")
    }

    @Test("learn with an empty embedding is a no-op")
    func learnIgnoresEmpty() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.learn(name: "Sam", embedding: [], seconds: 60)
        #expect(lib.all().first?.samples.count == 1)
    }

    @Test("upsert still replaces all samples (deliberate reset)")
    func upsertResets() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.learn(name: "Sam", embedding: [0, 1, 0], seconds: 120)
        try lib.upsert(name: "Sam", embedding: [0, 0, 1], isMe: false)
        #expect(lib.all().first?.samples.count == 1)
        #expect(lib.all().first?.samples.first?.embedding == [0, 0, 1])
    }
}

@Suite("MeetingSpeakerMap.duration(forLabel:)")
struct MeetingSpeakerMapDurationTests {
    @Test("returns the cluster's recorded duration by its current label")
    func durationLookup() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam"],
            embeddingByCluster: ["c1": [0, 1, 0]],
            durationByCluster: ["c1": 42])
        #expect(map.duration(forLabel: "Sam") == 42)
        #expect(map.duration(forLabel: "Nobody") == nil)
    }
}
