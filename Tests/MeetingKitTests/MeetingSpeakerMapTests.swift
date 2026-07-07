import Foundation
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
        #expect(map.labelByCluster["c0"] == "Me")  // others untouched
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

/// Renaming a junk cluster (seconds of noise) must not teach the library its
/// voiceprint — that's how "Joshua Li" became a magnet for noise. The transcript
/// rename itself still happens; only the learning is gated.
@Suite("MeetingSpeakerMap learning gate")
struct MeetingSpeakerMapLearningTests {

    private func map(duration: TimeInterval?) -> MeetingSpeakerMap {
        MeetingSpeakerMap(
            labelByCluster: ["c1": "Speaker 2"],
            embeddingByCluster: ["c1": [0, 1, 0]],
            durationByCluster: duration.map { ["c1": $0] } ?? [:]
        )
    }

    @Test("a cluster with enough speech is learnable")
    func longClusterLearns() {
        #expect(map(duration: 60).learnableVoiceprint(forLabel: "Speaker 2") == [0, 1, 0])
    }

    @Test("a short cluster is not learnable")
    func shortClusterDoesNotLearn() {
        #expect(map(duration: 5).learnableVoiceprint(forLabel: "Speaker 2") == nil)
    }

    @Test("legacy maps without durations still learn (preserve old behavior)")
    func legacyMapLearns() {
        #expect(map(duration: nil).learnableVoiceprint(forLabel: "Speaker 2") == [0, 1, 0])
    }

    @Test("unknown label is not learnable")
    func unknownLabel() {
        #expect(map(duration: 60).learnableVoiceprint(forLabel: "Nobody") == nil)
    }

    @Test("maps saved before durations existed still decode")
    func legacyDecode() throws {
        let legacy = """
            {"labelByCluster": {"c0": "Me"}, "embeddingByCluster": {"c0": [1, 0, 0]}}
            """
        let map = try JSONDecoder().decode(
            MeetingSpeakerMap.self, from: Data(legacy.utf8))
        #expect(map.labelByCluster == ["c0": "Me"])
        #expect(map.durationByCluster.isEmpty)
    }
}
