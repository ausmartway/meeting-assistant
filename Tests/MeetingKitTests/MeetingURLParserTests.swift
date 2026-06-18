import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingURLParser")
struct MeetingURLParserTests {

    @Test("finds a Zoom URL in the notes body")
    func findsZoomURLInNotes() {
        let notes = "Join Zoom Meeting\nhttps://us02web.zoom.us/j/8412345678?pwd=abcDEF\nMeeting ID: 841 234 5678"
        let result = MeetingURLParser.parse(url: nil, notes: notes, location: nil)
        #expect(result?.provider == .zoom)
        #expect(result?.url.absoluteString == "https://us02web.zoom.us/j/8412345678?pwd=abcDEF")
    }

    @Test("finds a Google Meet URL in the location field")
    func findsGoogleMeetURLInLocation() {
        let result = MeetingURLParser.parse(url: nil, notes: nil, location: "https://meet.google.com/abc-defg-hij")
        #expect(result?.provider == .googleMeet)
        #expect(result?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("finds a Microsoft Teams meetup-join URL in the notes")
    func findsTeamsURLInNotes() {
        let notes = "________________________________\nMicrosoft Teams meeting\nJoin on your computer\nhttps://teams.microsoft.com/l/meetup-join/19%3ameeting_abcd/0?context=%7b%7d\n"
        let result = MeetingURLParser.parse(url: nil, notes: notes, location: nil)
        #expect(result?.provider == .microsoftTeams)
        #expect(result?.url.absoluteString.hasPrefix("https://teams.microsoft.com/l/meetup-join/") == true)
    }

    @Test("prefers a dedicated url field over a link in notes")
    func prefersDedicatedURLFieldOverNotes() {
        let url = URL(string: "https://us02web.zoom.us/j/111?pwd=xyz")!
        let notes = "Backup: https://meet.google.com/aaa-bbbb-ccc"
        let result = MeetingURLParser.parse(url: url, notes: notes, location: nil)
        #expect(result?.provider == .zoom)
        #expect(result?.url == url)
    }

    @Test("ignores a non-meeting url field and falls through to notes")
    func ignoresNonMeetingURLField() {
        let url = URL(string: "https://example.com/agenda")!
        let notes = "https://meet.google.com/aaa-bbbb-ccc"
        let result = MeetingURLParser.parse(url: url, notes: notes, location: nil)
        #expect(result?.provider == .googleMeet)
    }

    @Test("returns nil when there is no meeting link anywhere")
    func returnsNilWhenNoMeetingLink() {
        let result = MeetingURLParser.parse(url: nil, notes: "Discuss roadmap in room 4B", location: "Room 4B")
        #expect(result == nil)
    }

    @Test("finds a Webex j.php join URL in the notes body")
    func findsWebexURLInNotes() {
        let notes = "Cisco Webex meeting\nJoin: https://acme.webex.com/acme/j.php?MTID=m1234567890\n"
        let result = MeetingURLParser.parse(url: nil, notes: notes, location: nil)
        #expect(result?.provider == .webex)
        #expect(result?.url.absoluteString == "https://acme.webex.com/acme/j.php?MTID=m1234567890")
    }

    @Test("finds a Webex personal-room URL in the location field")
    func findsWebexPersonalRoomURLInLocation() {
        let result = MeetingURLParser.parse(url: nil, notes: nil, location: "https://acme.webex.com/meet/john.doe")
        #expect(result?.provider == .webex)
        #expect(result?.url.absoluteString == "https://acme.webex.com/meet/john.doe")
    }
}
