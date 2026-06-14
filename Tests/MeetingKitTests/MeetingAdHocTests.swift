import Testing
import Foundation
@testable import MeetingKit

@Suite("Meeting.adHoc")
struct MeetingAdHocTests {

    @Test("names the meeting after the detected provider")
    func usesProviderNameInTitle() {
        let start = Date(timeIntervalSince1970: 1000)
        let m = Meeting.adHoc(id: "x", provider: .zoom, start: start)
        #expect(m.title == "Zoom meeting")
        #expect(m.provider == .zoom)
        #expect(m.startDate == start)
        #expect(m.endDate == start.addingTimeInterval(2 * 60 * 60))
        #expect(m.joinURL == nil)
    }

    @Test("falls back to a generic title when no provider is detected")
    func genericTitleWhenNoProvider() {
        let m = Meeting.adHoc(id: "x", provider: nil, start: Date(timeIntervalSince1970: 0))
        #expect(m.title == "Ad-hoc meeting")
        #expect(m.provider == nil)
    }
}
