import Testing

@testable import MeetingKit

@Suite struct LocalUserNameTests {
    @Test func overrideWins() {
        #expect(LocalUserName.resolve(override: "Nick", accountName: "Yulei Liu") == "Nick")
    }
    @Test func blankOverrideFallsBackToAccount() {
        #expect(LocalUserName.resolve(override: "   ", accountName: "Yulei Liu") == "Yulei Liu")
    }
    @Test func bothBlankIsMe() {
        #expect(LocalUserName.resolve(override: "", accountName: "  ") == "Me")
    }
    @Test func trimsWhitespace() {
        #expect(LocalUserName.resolve(override: "  Sam  ", accountName: "x") == "Sam")
    }
}
