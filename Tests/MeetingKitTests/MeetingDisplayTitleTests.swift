import Testing

@testable import MeetingKit

@Suite("MeetingDisplayTitle.sidebarTitle")
struct MeetingDisplayTitleTests {

    @Test("generic provider title gets a named remote speaker appended")
    func genericGetsSpeaker() {
        let out = MeetingDisplayTitle.sidebarTitle(
            title: "Microsoft Teams meeting",
            providerDisplayName: "Microsoft Teams",
            providerShortName: "Teams",
            speakers: ["Me", "Cameron Huysman"],
            localUserName: "Me")
        #expect(out == "Microsoft Teams meeting · Cameron Huysman")
    }

    @Test("a non-generic (user/calendar) title is unchanged")
    func nonGenericUnchanged() {
        let out = MeetingDisplayTitle.sidebarTitle(
            title: "Vault to support ATC training",
            providerDisplayName: "Microsoft Teams",
            providerShortName: "Teams",
            speakers: ["Me", "Cameron Huysman"],
            localUserName: "Me")
        #expect(out == "Vault to support ATC training")
    }

    @Test("generic title with only anonymous/Me speakers is unchanged")
    func noNamedRemote() {
        let out = MeetingDisplayTitle.sidebarTitle(
            title: "Microsoft Teams meeting",
            providerDisplayName: "Microsoft Teams",
            providerShortName: "Teams",
            speakers: ["Me", "Speaker 2"],
            localUserName: "Me")
        #expect(out == "Microsoft Teams meeting")
    }

    @Test("generic title with no speakers is unchanged")
    func emptySpeakers() {
        let out = MeetingDisplayTitle.sidebarTitle(
            title: "ad-hoc meeting",
            providerDisplayName: nil,
            providerShortName: nil,
            speakers: [],
            localUserName: "Me")
        #expect(out == "ad-hoc meeting")
    }

    @Test("the local user is skipped even when named (not 'Me')")
    func skipsLocalByName() {
        let out = MeetingDisplayTitle.sidebarTitle(
            title: "ad-hoc meeting",
            providerDisplayName: nil,
            providerShortName: nil,
            speakers: ["Yulei", "Cameron Huysman"],
            localUserName: "Yulei")
        #expect(out == "ad-hoc meeting · Cameron Huysman")
    }

    @Test("ad-hoc short-name and Untitled are also generic")
    func otherGenerics() {
        #expect(
            MeetingDisplayTitle.sidebarTitle(
                title: "ad-hoc Teams", providerDisplayName: "Microsoft Teams",
                providerShortName: "Teams", speakers: ["Robin"], localUserName: "Me")
                == "ad-hoc Teams · Robin")
        #expect(
            MeetingDisplayTitle.sidebarTitle(
                title: "Untitled meeting", providerDisplayName: nil, providerShortName: nil,
                speakers: ["Robin"], localUserName: "Me")
                == "Untitled meeting · Robin")
    }
}
