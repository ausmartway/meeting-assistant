import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingNotification.resolve")
struct MeetingNotificationTests {

    private func meeting(id: String, title: String = "Standup", provider: MeetingProvider? = .zoom) -> Meeting {
        Meeting(
            id: id,
            title: title,
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 1000 + 1800),
            provider: provider,
            joinURL: nil
        )
    }

    @Test("round-trips userInfo and returns the live meeting when still upcoming")
    func resolvesFromUpcoming() {
        let live = meeting(id: "abc", title: "Standup", provider: .googleMeet)
        let info = MeetingNotification.userInfo(for: live)
        let resolved = MeetingNotification.resolve(
            userInfo: info, upcoming: [live], now: Date(timeIntervalSince1970: 2000)
        )
        #expect(resolved == live)   // exact meeting, with real dates/joinURL preserved
    }

    @Test("reconstructs an ad-hoc meeting from the payload when no longer upcoming")
    func reconstructsWhenGone() {
        let info = MeetingNotification.userInfo(for: meeting(id: "abc", title: "Sync", provider: .microsoftTeams))
        let now = Date(timeIntervalSince1970: 5000)
        let resolved = MeetingNotification.resolve(userInfo: info, upcoming: [], now: now)
        #expect(resolved?.id == "abc")
        #expect(resolved?.title == "Sync")
        #expect(resolved?.provider == .microsoftTeams)
        #expect(resolved?.startDate == now)
        #expect(resolved?.endDate == now.addingTimeInterval(2 * 60 * 60))
        #expect(resolved?.joinURL == nil)
    }

    @Test("preserves a nil provider through reconstruction")
    func reconstructsWithoutProvider() {
        let info = MeetingNotification.userInfo(for: meeting(id: "x", title: "Chat", provider: nil))
        let resolved = MeetingNotification.resolve(userInfo: info, upcoming: [], now: Date(timeIntervalSince1970: 0))
        #expect(resolved?.provider == nil)
        #expect(resolved?.title == "Chat")
    }

    @Test("returns nil for a payload missing the meeting id")
    func nilOnMalformedPayload() {
        let resolved = MeetingNotification.resolve(userInfo: ["unrelated": "value"], upcoming: [], now: Date())
        #expect(resolved == nil)
    }
}
