import Foundation
import Testing

@testable import MeetingKit

@Suite struct SpeakerLibraryLocalUserTests {
    private func makeLib() -> SpeakerLibrary {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-lib-\(UUID().uuidString).json")
        return SpeakerLibrary(url: url)
    }

    @Test func renamesTheIsMeEntryAndKeepsVoiceprint() throws {
        let lib = makeLib()
        try lib.upsert(name: "Me", embedding: [1, 2, 3], isMe: true)
        try lib.upsert(name: "Sam", embedding: [4, 5, 6], isMe: false)
        try lib.setLocalUserName("Yulei Liu")
        let me = lib.me
        #expect(me?.name == "Yulei Liu")
        #expect(me?.isMe == true)
        #expect(me?.samples[0].embedding == [1, 2, 3])
        #expect(lib.all().contains { $0.name == "Sam" && !$0.isMe })
    }

    @Test func noopWhenAlreadyCorrect() throws {
        let lib = makeLib()
        try lib.upsert(name: "Yulei Liu", embedding: [1], isMe: true)
        let before = lib.me?.updatedAt
        try lib.setLocalUserName("Yulei Liu")
        #expect(lib.me?.updatedAt == before)
    }

    @Test func noopWhenNotEnrolled() throws {
        let lib = makeLib()
        try lib.upsert(name: "Sam", embedding: [1], isMe: false)
        try lib.setLocalUserName("Yulei Liu")
        #expect(lib.me == nil)
        #expect(lib.all().count == 1)
    }
}
