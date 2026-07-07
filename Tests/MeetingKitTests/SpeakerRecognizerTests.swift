import Foundation
import Testing

@testable import MeetingKit

@Suite("SpeakerRecognizer")
struct SpeakerRecognizerTests {
    /// Clusters get 30 s of speech each — comfortably past the trust floor, so
    /// these tests exercise the embedding logic, not the duration gate.
    private func outcome(_ pairs: [(String, [Float])], spanLength: Double = 30)
        -> DiarizationOutcome
    {
        var spans: [DiarizedSpan] = []
        var emb: [String: [Float]] = [:]
        var t = 0.0
        for (id, e) in pairs {
            spans.append(DiarizedSpan(start: t, end: t + spanLength, speakerID: id))
            emb[id] = e
            t += spanLength
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

    // The "Joshua Li" bug: a junk cluster (a few seconds of noise / garbled audio)
    // sat extremely close to a known voiceprint and confidently took a real
    // person's name. However good the embedding match, a cluster with almost no
    // speech behind it is not evidence someone was in the meeting.

    @Test("a short cluster never takes a known name, even on a perfect match")
    func shortClusterStaysAnonymous() {
        let lib = [known("Joshua", [1, 0, 0])]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("junk", [1, 0, 0])], spanLength: 5),
            knownSpeakers: lib, threshold: 0.4)
        #expect(labels["junk"] == "Speaker 2")
    }

    @Test("duration gate sums a cluster's spans, not just one")
    func durationSumsAcrossSpans() {
        // Three 6 s spans = 18 s total — past the floor even though each span alone
        // is under it.
        let lib = [known("Sam", [1, 0, 0])]
        let spans = [
            DiarizedSpan(start: 0, end: 6, speakerID: "c0"),
            DiarizedSpan(start: 20, end: 26, speakerID: "c0"),
            DiarizedSpan(start: 40, end: 46, speakerID: "c0"),
        ]
        let labels = SpeakerRecognizer.resolve(
            outcome: DiarizationOutcome(spans: spans, embeddings: ["c0": [1, 0, 0]]),
            knownSpeakers: lib, threshold: 0.4)
        #expect(labels["c0"] == "Sam")
    }

    @Test("short clusters keep their anonymous numbering position")
    func shortClusterNumbering() {
        let lib = [known("Sam", [1, 0, 0])]
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("junk", [1, 0, 0]), ("real", [1, 0, 0])], spanLength: 5)
                .with(extraSpans: [DiarizedSpan(start: 100, end: 130, speakerID: "real")]),
            knownSpeakers: lib, threshold: 0.4)
        // "junk" (5 s) is anonymous; "real" (5 + 30 s) wins the name.
        #expect(labels["junk"] == "Speaker 2")
        #expect(labels["real"] == "Sam")
    }

    @Test("speechDuration sums per-cluster span lengths")
    func speechDurationHelper() {
        let spans = [
            DiarizedSpan(start: 0, end: 6, speakerID: "a"),
            DiarizedSpan(start: 10, end: 12, speakerID: "b"),
            DiarizedSpan(start: 20, end: 26, speakerID: "a"),
        ]
        let durations = SpeakerRecognizer.speechDuration(byCluster: spans)
        #expect(durations["a"] == 12)
        #expect(durations["b"] == 2)
    }
}

extension DiarizationOutcome {
    fileprivate func with(extraSpans: [DiarizedSpan]) -> DiarizationOutcome {
        DiarizationOutcome(spans: spans + extraSpans, embeddings: embeddings)
    }
}

@Suite struct SpeakerRecognizerStartingAnonTests {
    @Test("startingAnon offsets anonymous numbering for a second channel")
    func startingAnonOffsets() {
        let outcome = DiarizationOutcome(
            spans: [
                DiarizedSpan(start: 0, end: 1, speakerID: "c1"),
                DiarizedSpan(start: 1, end: 2, speakerID: "c2"),
            ],
            embeddings: ["c1": [1, 0, 0], "c2": [0, 1, 0]])
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome, knownSpeakers: [], startingAnon: 5)
        #expect(labels["c1"] == "Speaker 5")
        #expect(labels["c2"] == "Speaker 6")
    }
}
