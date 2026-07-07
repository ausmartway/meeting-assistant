import Foundation
import Testing

@testable import MeetingKit

@Suite("LibraryRefinement")
struct LibraryRefinementTests {
    private let known = [
        KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0]),
        KnownSpeaker(name: "Yulei", isMe: true, embedding: [0, 1, 0]),
    ]

    @Test("confidently-labeled clusters produce updates; anonymous ones don't")
    func matchedClustersOnly() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam", "c2": "Speaker 2", "sys:S1": "Yulei"],
            embeddingByCluster: ["c1": [1, 0, 0], "c2": [0, 0, 1], "sys:S1": [0, 1, 0]],
            durationByCluster: ["c1": 60, "c2": 60, "sys:S1": 90])
        let updates = LibraryRefinement.updates(map: map, known: known)
        #expect(updates.count == 2)
        #expect(updates[0] == .init(name: "Sam", embedding: [1, 0, 0], seconds: 60))
        #expect(updates[1] == .init(name: "Yulei", embedding: [0, 1, 0], seconds: 90))
    }

    @Test("label matching is case-insensitive, using the library's spelling")
    func caseInsensitive() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "sam"],
            embeddingByCluster: ["c1": [1, 0, 0]],
            durationByCluster: ["c1": 60])
        #expect(LibraryRefinement.updates(map: map, known: known).first?.name == "Sam")
    }

    @Test("clusters under the trust floor or without recorded durations are skipped")
    func gatesEnforced() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam", "c2": "Yulei"],
            embeddingByCluster: ["c1": [1, 0, 0], "c2": [0, 1, 0]],
            durationByCluster: ["c1": 5])  // c1 too short; c2 legacy (no duration)
        #expect(LibraryRefinement.updates(map: map, known: known).isEmpty)
    }

    @Test("clusters with missing embeddings are skipped")
    func missingEmbedding() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam"],
            embeddingByCluster: [:],
            durationByCluster: ["c1": 60])
        #expect(LibraryRefinement.updates(map: map, known: known).isEmpty)
    }
}
