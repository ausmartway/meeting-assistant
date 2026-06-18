import Testing

@testable import MeetingKit

@Suite struct MeetingProviderBundleIDsTests {
    @Test func zoomIsNativeOnly() {
        #expect(MeetingProvider.zoom.meetingAppBundleIDs == ["us.zoom.xos"])
    }

    @Test func meetIsBrowsersOnly() {
        #expect(MeetingProvider.googleMeet.meetingAppBundleIDs == MeetingProvider.browserBundleIDs)
    }

    @Test func teamsIncludesNativeAndBrowsers() {
        let ids = MeetingProvider.microsoftTeams.meetingAppBundleIDs
        #expect(ids.contains("com.microsoft.teams"))
        #expect(ids.contains("com.microsoft.teams2"))
        #expect(ids.isSuperset(of: MeetingProvider.browserBundleIDs))
    }

    @Test func webexIncludesNativeAndBrowsers() {
        let ids = MeetingProvider.webex.meetingAppBundleIDs
        #expect(ids.contains("com.cisco.webexmeetings"))
        #expect(ids.isSuperset(of: MeetingProvider.browserBundleIDs))
    }
}
