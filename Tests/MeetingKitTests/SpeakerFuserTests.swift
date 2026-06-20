import Testing

@testable import MeetingKit

@Suite("SpeakerFuser")
struct SpeakerFuserTests {

    private func sys(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, channel: .system)
    }
    private func mic(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, channel: .microphone)
    }

    @Test("labels microphone segments as the local user regardless of the timeline")
    func micSegmentsAreMe() {
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Alice")])
        let out = SpeakerFuser.fuse(segments: [mic(1, 2, "Hi all")], timeline: timeline)
        #expect(out == [LabeledSegment(start: 1, end: 2, text: "Hi all", speaker: "Me")])
    }

    @Test("labels a system segment with the speaker highlighted at its midpoint")
    func systemSegmentUsesActiveSpeaker() {
        let timeline = SpeakerTimeline(samples: [
            SpeakerSample(timestamp: 0, speakerName: "Alice"),
            SpeakerSample(timestamp: 10, speakerName: "Bob"),
        ])
        let out = SpeakerFuser.fuse(
            segments: [sys(3, 5, "point one"), sys(11, 13, "point two")], timeline: timeline)
        #expect(out.map(\.speaker) == ["Alice", "Bob"])
    }

    @Test("uses the most recent sample at or before the segment midpoint")
    func usesLatestSampleAtOrBeforeMidpoint() {
        let timeline = SpeakerTimeline(samples: [
            SpeakerSample(timestamp: 0, speakerName: "Alice"),
            SpeakerSample(timestamp: 6, speakerName: "Bob"),
        ])
        // midpoint = 5 → latest at-or-before is t=0 → Alice
        let out = SpeakerFuser.fuse(segments: [sys(4, 6, "still alice")], timeline: timeline)
        #expect(out.first?.speaker == "Alice")
    }

    @Test("falls back to the unknown label when the active sample has no name")
    func fallsBackToUnknownLabel() {
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: nil)])
        let out = SpeakerFuser.fuse(segments: [sys(1, 2, "who is this")], timeline: timeline)
        #expect(out.first?.speaker == "Speaker")
    }

    @Test("falls back to the unknown label when the timeline is empty")
    func fallsBackWhenTimelineEmpty() {
        let out = SpeakerFuser.fuse(
            segments: [sys(1, 2, "no timeline")], timeline: SpeakerTimeline(samples: []))
        #expect(out.first?.speaker == "Speaker")
    }

    @Test("uses the earliest sample for a segment that precedes all samples")
    func usesEarliestSampleBeforeFirst() {
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 5, speakerName: "Alice")])
        // midpoint = 1, before the first sample at t=5 → best guess is the first sample
        let out = SpeakerFuser.fuse(segments: [sys(0, 2, "early words")], timeline: timeline)
        #expect(out.first?.speaker == "Alice")
    }

    @Test("mic segments resolve to diarized speakers when spans are provided")
    func micDiarizationLabels() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone),
            TranscriptSegment(start: 2, end: 3, text: "hello", channel: .microphone),
        ]
        let spans = [
            DiarizedSpan(start: 0, end: 1.5, speakerID: "Me"),
            DiarizedSpan(start: 1.5, end: 4, speakerID: "spk_a"),
        ]
        let out = SpeakerFuser.fuse(
            segments: segments,
            timeline: SpeakerTimeline(samples: []),
            micDiarization: spans,
            micLabels: ["Me": "Me", "spk_a": "Speaker 2"]
        )
        #expect(out.map(\.speaker) == ["Me", "Speaker 2"])
    }

    @Test("with no diarization spans, mic stays 'Me' (unchanged behavior)")
    func micFallsBackToMe() {
        let segments = [TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone)]
        let out = SpeakerFuser.fuse(segments: segments, timeline: SpeakerTimeline(samples: []))
        #expect(out.map(\.speaker) == ["Me"])
    }

    @Test("mic segment whose midpoint is in a diarization gap falls back to 'Me'")
    func micGapFallsBackToMe() {
        let segments = [TranscriptSegment(start: 5, end: 6, text: "x", channel: .microphone)]
        let spans = [DiarizedSpan(start: 0, end: 1, speakerID: "spk_a")]
        let out = SpeakerFuser.fuse(
            segments: segments,
            timeline: SpeakerTimeline(samples: []),
            micDiarization: spans,
            micLabels: ["spk_a": "Speaker 2"]
        )
        #expect(out.map(\.speaker) == ["Me"])
    }

    @Test("mic segments carry the supplied local-user label")
    func micLabelHonored() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone)]
        let out = SpeakerFuser.fuse(
            segments: segs, timeline: SpeakerTimeline(samples: []),
            micDiarization: [], micLabels: [:], micLabel: "Yulei Liu")
        #expect(out.first?.speaker == "Yulei Liu")
    }
}
