import Testing
import Foundation
@testable import MeetingKit

@Suite("SpeakerLibrary")
struct SpeakerLibraryTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spk-\(UUID().uuidString).json")
    }

    @Test("upsert adds, persists, and reloads")
    func upsertPersists() throws {
        let url = tempURL()
        let lib = SpeakerLibrary(url: url)
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        let reloaded = SpeakerLibrary(url: url)
        #expect(reloaded.all().map(\.name) == ["Sam"])
        #expect(reloaded.all().first?.embedding == [1, 0, 0])
    }

    @Test("upsert of an existing name updates its voiceprint, not a duplicate")
    func upsertMerges() throws {
        let url = tempURL()
        let lib = SpeakerLibrary(url: url)
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.upsert(name: "Sam", embedding: [0, 1, 0], isMe: false)
        #expect(lib.all().count == 1)
        #expect(lib.all().first?.embedding == [0, 1, 0])
    }

    @Test("me returns the isMe speaker")
    func meAccessor() throws {
        let lib = SpeakerLibrary(url: tempURL())
        try lib.upsert(name: "Me", embedding: [1, 1, 1], isMe: true)
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        #expect(lib.me?.name == "Me")
    }

    @Test("rename changes the name and persists")
    func rename() throws {
        let url = tempURL()
        let lib = SpeakerLibrary(url: url)
        try lib.upsert(name: "Speaker 2", embedding: [1, 0, 0], isMe: false)
        let id = lib.all().first!.id
        try lib.rename(id: id, to: "Pat")
        #expect(SpeakerLibrary(url: url).all().map(\.name) == ["Pat"])
    }

    @Test("delete removes a speaker")
    func delete() throws {
        let url = tempURL()
        let lib = SpeakerLibrary(url: url)
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        let id = lib.all().first!.id
        try lib.delete(id: id)
        #expect(SpeakerLibrary(url: url).all().isEmpty)
    }
}
