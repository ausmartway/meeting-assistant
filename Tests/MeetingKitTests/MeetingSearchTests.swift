import Foundation
import Testing

@testable import MeetingKit

@Suite struct MeetingSearchTests {
    func rec(_ id: String, _ title: String) -> MeetingRecording {
        let m = Meeting(
            id: id, title: title,
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 0),
            provider: nil, joinURL: nil)
        return MeetingRecording(
            meeting: m, recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: []))
    }

    var recs: [MeetingRecording] {
        [rec("a", "Standup"), rec("b", "Weekly Sync"), rec("c", "1:1")]
    }
    var index: [String: String] {
        [
            "a": "standup mon jun 18 2026 quarterly numbers",
            "b": "weekly sync jun 18 2026 roadmap planning",
            "c": "1:1 jun 19 2026 career growth",
        ]
    }

    @Test func emptyQueryReturnsAllInOrder() {
        let out = MeetingSearch.filter(recs, query: "", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["a", "b", "c"])
    }

    @Test func whitespaceQueryReturnsAll() {
        #expect(MeetingSearch.filter(recs, query: "   ", haystackByID: index).count == 3)
    }

    @Test func titleSubstringMatch() {
        let out = MeetingSearch.filter(recs, query: "weekly", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["b"])
    }

    @Test func caseInsensitive() {
        let out = MeetingSearch.filter(recs, query: "STANDUP", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["a"])
    }

    @Test func trimmedQuery() {
        let out = MeetingSearch.filter(recs, query: "  roadmap  ", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["b"])
    }

    @Test func dateMatch() {
        let out = MeetingSearch.filter(recs, query: "jun 19", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["c"])
    }

    @Test func transcriptTextMatch() {
        let out = MeetingSearch.filter(recs, query: "career", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["c"])
    }

    @Test func noMatchIsEmpty() {
        #expect(MeetingSearch.filter(recs, query: "zzz", haystackByID: index).isEmpty)
    }

    @Test func recordingAbsentFromIndexIsExcluded() {
        let partial = ["a": "standup", "c": "1:1"]
        let out = MeetingSearch.filter(recs, query: "weekly", haystackByID: partial)
        #expect(out.isEmpty)
    }

    @Test func baseHaystackLowercasesAndIncludesTitle() {
        let h = MeetingSearch.baseHaystack(for: rec("x", "Weekly Sync"))
        #expect(h.contains("weekly sync"))
        #expect(h == h.lowercased())
    }
}
