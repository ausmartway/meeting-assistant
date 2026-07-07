import Foundation
import Testing

@testable import MeetingKit

@Suite("TranscriptAudioLocator")
struct TranscriptAudioLocatorTests {
    let tz = TimeZone(identifier: "Australia/Sydney")!
    // 2026-07-07 14:00:00 AEST
    var recordedAt: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 14))!
    }
    func turn(_ time: String, _ speaker: String) -> TranscriptParser.Turn {
        TranscriptParser.Turn(time: time, speaker: speaker, text: "…")
    }
    func locate(
        _ turns: [TranscriptParser.Turn], segments: [LabeledSegment]?,
        recordedAt: Date? = nil
    ) -> [TranscriptAudioLocator.ClipLocation?] {
        TranscriptAudioLocator.locate(
            turns: turns, segments: segments, recordedAt: recordedAt ?? self.recordedAt,
            localUserName: "Yulei Liu", micFileName: "mic.wav",
            systemFileName: "system.wav", timeZone: tz)
    }

    @Test("precise: segments pair by index with exact start/end and channel file")
    func precisePairing() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: .microphone),
            LabeledSegment(start: 9.5, end: 20, text: "…", speaker: "Sam", channel: .system),
        ]
        // Rendered stamps for starts 5s and 9.5s after 14:00:00.
        let turns = [turn("14:00:05", "Yulei Liu"), turn("14:00:09", "Sam")]
        let clips = locate(turns, segments: segments)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
        #expect(clips[1] == .init(fileName: "system.wav", start: 9.5, end: 20))
    }

    @Test("precise: a speaker mismatch at an index falls back for that turn only")
    func sanityCheckFallsBack() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: .microphone),
            LabeledSegment(start: 9.5, end: 20, text: "…", speaker: "Sam", channel: .system),
        ]
        // Second turn's speaker was renamed after processing → mismatch.
        let turns = [turn("14:00:05", "Yulei Liu"), turn("14:00:09", "Dinesh")]
        let clips = locate(turns, segments: segments)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
        // Fallback for turn 1: offset 9s from stamp, last turn → +15s, non-local → system.
        #expect(clips[1] == .init(fileName: "system.wav", start: 9, end: 24))
    }

    @Test("precise: nil segment channel uses the label-based file guess")
    func nilChannelGuess() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: nil)
        ]
        let clips = locate([turn("14:00:05", "Yulei Liu")], segments: segments)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
    }

    @Test("fallback: offsets derive from wall-clock stamps; end is next turn capped at 30s")
    func fallbackOffsets() {
        let turns = [
            turn("14:00:10", "Yulei Liu"),  // next turn 100s later → capped at +30
            turn("14:01:50", "Sam"),  // last turn → +15
        ]
        let clips = locate(turns, segments: nil)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 10, end: 40))
        #expect(clips[1] == .init(fileName: "system.wav", start: 110, end: 125))
    }

    @Test("fallback: midnight wrap adds 24h")
    func midnightWrap() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let lateNight = cal.date(
            from: DateComponents(year: 2026, month: 7, day: 7, hour: 23, minute: 59, second: 30))!
        let clips = locate([turn("00:00:10", "Sam")], segments: nil, recordedAt: lateNight)
        #expect(clips[0] == .init(fileName: "system.wav", start: 40, end: 55))
    }

    @Test("fallback: two-component MM:SS stamps are meeting-relative offsets")
    func relativeStamps() {
        let clips = locate([turn("00:05", "Sam")], segments: nil)
        #expect(clips[0] == .init(fileName: "system.wav", start: 5, end: 20))
    }

    @Test("unparsable or empty stamps yield nil for that turn")
    func unparsableStamp() {
        let clips = locate([turn("", "Sam"), turn("bogus", "Sam")], segments: nil)
        #expect(clips == [nil, nil])
    }

    @Test("segment/turn count mismatch falls back wholesale")
    func countMismatch() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: .microphone)
        ]
        let turns = [turn("14:00:05", "Yulei Liu"), turn("14:00:09", "Sam")]
        let clips = locate(turns, segments: segments)
        // Both fall back to stamp-derived windows.
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
        #expect(clips[1] == .init(fileName: "system.wav", start: 9, end: 24))
    }

    @Test("precise: consecutive same-speaker segments merge into one group like the formatter")
    func mergesSameSpeakerRuns() {
        // Mirrors real meetings: TranscriptFormatter merges consecutive
        // same-speaker segments into one rendered line, so segments.count
        // (5) != turns.count after merge (3) unless the locator groups the
        // same way. Three consecutive "Dinesh" mic segments (an in-room,
        // non-local named speaker) must still resolve to the precise
        // mic.wav clip spanning the whole run — not fall back to the
        // label-guessed system.wav.
        let segments = [
            LabeledSegment(
                start: 0, end: 5, text: "hello", speaker: "Yulei Liu", channel: .microphone),
            LabeledSegment(start: 5, end: 8, text: "hi", speaker: "Dinesh", channel: .microphone),
            LabeledSegment(
                start: 8, end: 9, text: "there", speaker: "Dinesh", channel: .microphone),
            LabeledSegment(
                start: 9, end: 12, text: "folks", speaker: "Dinesh", channel: .microphone),
            LabeledSegment(start: 12, end: 20, text: "yep", speaker: "Sam", channel: .system),
        ]
        let meeting = Meeting(
            id: "m1", title: "Standup", startDate: recordedAt, endDate: recordedAt,
            provider: nil, joinURL: nil)
        let rendered = TranscriptFormatter.document(
            meeting: meeting, segments: segments, baseDate: recordedAt)
        let parsed = TranscriptParser.parse(rendered)
        #expect(parsed.turns.count == 3)  // merged: Yulei Liu, Dinesh, Sam

        let clips = locate(parsed.turns, segments: segments)
        #expect(clips.count == 3)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 0, end: 5))
        // The merged Dinesh run must resolve to the precise mic clip
        // spanning first segment's start to last segment's end — not the
        // fallback, which would guess system.wav for a non-local speaker.
        #expect(clips[1] == .init(fileName: "mic.wav", start: 5, end: 12))
        #expect(clips[2] == .init(fileName: "system.wav", start: 12, end: 20))
    }
}
