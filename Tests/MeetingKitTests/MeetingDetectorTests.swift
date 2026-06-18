import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingDetector.isWithinWindow")
struct MeetingDetectorTests {

    private func meeting(start: TimeInterval, end: TimeInterval) -> Meeting {
        Meeting(id: "m", title: "Sync",
                startDate: Date(timeIntervalSince1970: start),
                endDate: Date(timeIntervalSince1970: end),
                provider: .zoom, joinURL: nil)
    }

    @Test("true while the meeting is in progress")
    func during() {
        let m = meeting(start: 1000, end: 4600)   // 1h meeting
        #expect(MeetingDetector.isWithinWindow(m, now: Date(timeIntervalSince1970: 2000), grace: 120))
    }

    @Test("true within the grace window just before the start time")
    func graceBeforeStart() {
        let m = meeting(start: 1000, end: 4600)
        // 60s before start, grace 120 → allowed.
        #expect(MeetingDetector.isWithinWindow(m, now: Date(timeIntervalSince1970: 940), grace: 120))
    }

    @Test("false before the grace window opens")
    func tooEarly() {
        let m = meeting(start: 1000, end: 4600)
        // 5 min early, grace 120 → not yet.
        #expect(!MeetingDetector.isWithinWindow(m, now: Date(timeIntervalSince1970: 700), grace: 120))
    }

    @Test("false once the meeting has ended")
    func afterEnd() {
        let m = meeting(start: 1000, end: 4600)
        #expect(!MeetingDetector.isWithinWindow(m, now: Date(timeIntervalSince1970: 5000), grace: 120))
    }

    @Test("isInProgress: true during, within grace, false before grace / after end")
    func isInProgress() {
        let det = MeetingDetector()
        let m = meeting(start: 10_000, end: 13_600)   // 1h meeting, grace default 300
        #expect(det.isInProgress(m, now: Date(timeIntervalSince1970: 10_600)))   // 10 min in
        #expect(det.isInProgress(m, now: Date(timeIntervalSince1970: 9_800)))    // 200s before, within 300 grace
        #expect(!det.isInProgress(m, now: Date(timeIntervalSince1970: 9_600)))   // 400s before, beyond grace
        #expect(!det.isInProgress(m, now: Date(timeIntervalSince1970: 13_600)))  // exactly at end
        #expect(!det.isInProgress(m, now: Date(timeIntervalSince1970: 20_000)))  // after
    }

    @Test("a meeting with no provider never auto-starts")
    func noProvider() {
        let m = Meeting(id: "m", title: "Sync",
                        startDate: Date(timeIntervalSince1970: 1000),
                        endDate: Date(timeIntervalSince1970: 4600),
                        provider: nil, joinURL: nil)
        // In-window, but no provider → shouldAutoStart short-circuits to false
        // without touching NSWorkspace.
        #expect(!MeetingDetector().shouldAutoStart(m, now: Date(timeIntervalSince1970: 2000)))
    }
}
