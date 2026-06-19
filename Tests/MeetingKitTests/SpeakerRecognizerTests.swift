import Foundation
import Testing

@testable import MeetingKit

@Suite("SpeakerRecognizer")
struct SpeakerRecognizerTests {
    private func outcome(_ pairs: [(String, [Float])]) -> DiarizationOutcome {
        var spans: [DiarizedSpan] = []
        var emb: [String: [Float]] = [:]
        var t = 0.0
        for (id, e) in pairs {
            spans.append(DiarizedSpan(start: t, end: t + 1, speakerID: id))
            emb[id] = e
            t += 1
        }
        return DiarizationOutcome(spans: spans, embeddings: emb)
    }
    private func known(_ name: String, _ e: [Float], isMe: Bool = false) -> KnownSpeaker {
        KnownSpeaker(name: name, isMe: isMe, embedding: e)
    }

    @Test("confident match to a known speaker uses their name")
    func knownMatch() {
        let lib = [known("Me", [1, 0, 0], isMe: true), known("Sam", [0, 1, 0])]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("c0", [1, 0, 0]), ("c1", [0, 1, 0])]),
            knownSpeakers: lib, threshold: 0.3)
        #expect(labels["c0"] == "Me")
        #expect(labels["c1"] == "Sam")
    }

    @Test("weak (above-threshold) match stays an anonymous Speaker N")
    func weakMatch() {
        let lib = [known("Sam", [1, 0, 0])]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("c0", [0, 1, 0])]), knownSpeakers: lib, threshold: 0.3)
        #expect(labels["c0"] == "Speaker 2")
    }

    @Test("unmatched speakers are numbered from 2 by first appearance")
    func numbering() {
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("zzz", [9, 9, 9]), ("aaa", [8, 8, 8])]),
            knownSpeakers: [], threshold: 0.3)
        #expect(labels["zzz"] == "Speaker 2")
        #expect(labels["aaa"] == "Speaker 3")
    }

    @Test("mix: known speaker named, unknown numbered")
    func mix() {
        let lib = [known("Me", [1, 0, 0], isMe: true)]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("c0", [1, 0, 0]), ("c1", [0, 1, 0])]),
            knownSpeakers: lib, threshold: 0.3)
        #expect(labels["c0"] == "Me")
        #expect(labels["c1"] == "Speaker 2")
    }

    @Test("a known name is given to only the closest cluster; the rest go anonymous")
    func dedupKnownName() {
        // Two clusters both near "Sam"; c1 is closer (exact), c0 is slightly off.
        let lib = [known("Sam", [1, 0, 0])]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("c0", [0.9, 0.1, 0]), ("c1", [1, 0, 0])]),
            knownSpeakers: lib, threshold: 0.3)
        #expect(labels.values.filter { $0 == "Sam" }.count == 1)
        #expect(labels["c1"] == "Sam")  // closer cluster wins the name
        #expect(labels["c0"] == "Speaker 2")  // the other falls back to anonymous
    }

    @Test("ambiguous match between two known speakers stays anonymous")
    func ambiguousMatchIsAnonymous() {
        // c0 sits almost equidistant between Larry and Me (both well within the
        // threshold, only ~0.014 apart) — like a noisy / over-segmented voiceprint.
        // A confident match must clearly beat the runner-up, so this must NOT grab
        // "Larry" (the real-world bug: a fragment of the user's own voice was named
        // after a different person it happened to be marginally closer to).
        let lib = [known("Larry", [1, 0.1, 0]), known("Me", [1, 0.2, 0], isMe: true)]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("c0", [1, 0, 0])]),
            knownSpeakers: lib, threshold: 0.4)
        #expect(labels["c0"] == "Speaker 2")
    }
}
