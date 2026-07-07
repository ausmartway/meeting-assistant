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
}
