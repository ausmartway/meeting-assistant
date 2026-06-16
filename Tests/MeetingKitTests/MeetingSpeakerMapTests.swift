import Testing
@testable import MeetingKit

@Suite("MeetingSpeakerMap.relabel")
struct MeetingSpeakerMapTests {

    @Test("relabel renames the matching cluster and returns its voiceprint")
    func relabelMatch() {
        var map = MeetingSpeakerMap(
            labelByCluster: ["c0": "Me", "c1": "Speaker 2"],
            embeddingByCluster: ["c0": [1, 0, 0], "c1": [0, 1, 0]]
        )
        let embedding = map.relabel(from: "Speaker 2", to: "Sam")
        #expect(embedding == [0, 1, 0])
        #expect(map.labelByCluster["c1"] == "Sam")
        #expect(map.labelByCluster["c0"] == "Me")   // others untouched
    }

    @Test("relabel of an unknown label changes nothing and returns nil")
    func relabelMiss() {
        var map = MeetingSpeakerMap(
            labelByCluster: ["c0": "Me"],
            embeddingByCluster: ["c0": [1, 0, 0]]
        )
        let embedding = map.relabel(from: "Speaker 9", to: "Sam")
        #expect(embedding == nil)
        #expect(map.labelByCluster == ["c0": "Me"])
    }
}
