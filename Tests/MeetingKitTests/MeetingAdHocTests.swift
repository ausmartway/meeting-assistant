import Testing
import Foundation
@testable import MeetingKit

@Suite("Meeting.adHoc")
struct MeetingAdHocTests {

    @Test("names the meeting 'ad-hoc <software>' for a known provider")
    func usesProviderNameInTitle() {
        let start = Date(timeIntervalSince1970: 1000)
        let m = Meeting.adHoc(id: "x", provider: .zoom, start: start)
        #expect(m.title == "ad-hoc Zoom")
        #expect(m.provider == .zoom)
        #expect(m.startDate == start)
        #expect(m.endDate == start.addingTimeInterval(2 * 60 * 60))
        #expect(m.joinURL == nil)
    }

    @Test("uses the short software name (Teams, Meet, Webex)")
    func usesShortProviderNames() {
        #expect(Meeting.adHoc(id: "x", provider: .microsoftTeams, start: Date()).title == "ad-hoc Teams")
        #expect(Meeting.adHoc(id: "x", provider: .googleMeet, start: Date()).title == "ad-hoc Meet")
        #expect(Meeting.adHoc(id: "x", provider: .webex, start: Date()).title == "ad-hoc Webex")
    }

    @Test("falls back to a generic 'ad-hoc meeting' title when no provider")
    func genericTitleWhenNoProvider() {
        let m = Meeting.adHoc(id: "x", provider: nil, start: Date(timeIntervalSince1970: 0))
        #expect(m.title == "ad-hoc meeting")
        #expect(m.provider == nil)
    }
}
