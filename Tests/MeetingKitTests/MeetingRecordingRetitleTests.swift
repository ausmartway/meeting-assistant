import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingRecording.retitled")
struct MeetingRecordingRetitleTests {

    private func recording() -> MeetingRecording {
        let meeting = Meeting(
            id: "m1", title: "Original title",
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 2000),
            provider: .zoom,
            joinURL: URL(string: "https://zoom.us/j/123"))
        return MeetingRecording(
            meeting: meeting,
            recordedAt: Date(timeIntervalSince1970: 500),
            micAudioFile: "mic.wav",
            systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: [SpeakerSample(timestamp: 1, speakerName: "Ann")]),
            slides: [
                SlideKeyframe(timestamp: 391, file: "slides/slide-00391.jpg"),
                SlideKeyframe(timestamp: 512, file: "slides/slide-00512.jpg"),
            ])
    }

    @Test("the title changes")
    func titleChanges() {
        let updated = recording().retitled(to: "New title")
        #expect(updated.meeting.title == "New title")
    }

    @Test("slides survive — the regression this exists for")
    func slidesSurvive() {
        let original = recording()
        let updated = original.retitled(to: "New title")
        #expect(updated.slides == original.slides)
    }

    @Test("timeline, recordedAt, and both audio filenames survive")
    func otherRecordingFieldsSurvive() {
        let original = recording()
        let updated = original.retitled(to: "New title")
        #expect(updated.timeline == original.timeline)
        #expect(updated.recordedAt == original.recordedAt)
        #expect(updated.micAudioFile == original.micAudioFile)
        #expect(updated.systemAudioFile == original.systemAudioFile)
    }

    @Test("the meeting's id, dates, provider, and joinURL survive")
    func meetingIdentitySurvives() {
        let original = recording()
        let updated = original.retitled(to: "New title")
        #expect(updated.meeting.id == original.meeting.id)
        #expect(updated.meeting.startDate == original.meeting.startDate)
        #expect(updated.meeting.endDate == original.meeting.endDate)
        #expect(updated.meeting.provider == original.meeting.provider)
        #expect(updated.meeting.joinURL == original.meeting.joinURL)
    }
}
