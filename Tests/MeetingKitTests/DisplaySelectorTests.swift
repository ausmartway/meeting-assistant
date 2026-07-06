import CoreGraphics
import Foundation
import Testing

@testable import MeetingKit

@Suite struct DisplaySelectorTests {
    // Two side-by-side 1000-wide displays: #1 at x=0, #2 at x=1000.
    let d1 = ScreenDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let d2 = ScreenDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    var displays: [ScreenDisplay] { [d1, d2] }

    func win(_ x: CGFloat, w: CGFloat = 400, bundle: String?, pid: pid_t, id: CGWindowID = 1)
        -> ScreenWindow
    {
        ScreenWindow(
            windowID: id, frame: CGRect(x: x, y: 100, width: w, height: 300),
            bundleID: bundle, pid: pid)
    }

    @Test func preferredWindowOnSecondDisplayWins() {
        let windows = [
            win(100, w: 900, bundle: "com.other.app", pid: 10),
            win(1100, bundle: "us.zoom.xos", pid: 20),
        ]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 10)
        #expect(id == 2)
    }

    @Test func fallsBackToFrontmostWhenNoPreferred() {
        let windows = [
            win(100, bundle: "com.other.app", pid: 10),
            win(1100, bundle: "com.notes.app", pid: 20),
        ]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 20)
        #expect(id == 2)
    }

    @Test func nilWhenNeitherPreferredNorFrontmostMatch() {
        let windows = [win(100, bundle: "com.other.app", pid: 10)]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 999)
        #expect(id == nil)
    }

    @Test func largestPreferredWindowWins() {
        let windows = [
            win(50, w: 200, bundle: "us.zoom.xos", pid: 10),
            win(1100, w: 800, bundle: "us.zoom.xos", pid: 10),
        ]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: nil)
        #expect(id == 2)
    }

    @Test func displayIDForWindowUsesMaxOverlap() {
        // Window straddles the seam but mostly on display 1: x 400..1200 → 600 px on
        // display 1 (0..1000) vs 200 px on display 2 (1000..2000).
        let straddling = CGRect(x: 400, y: 100, width: 800, height: 300)
        #expect(DisplaySelector.displayID(forWindow: straddling, in: displays) == 1)
        let onD2 = CGRect(x: 1200, y: 100, width: 300, height: 300)
        #expect(DisplaySelector.displayID(forWindow: onD2, in: displays) == 2)
        let off = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        #expect(DisplaySelector.displayID(forWindow: off, in: displays) == nil)
    }
}

@Suite struct PickWindowTests {
    func win(
        _ w: CGFloat, bundle: String?, pid: pid_t, id: CGWindowID, title: String? = nil
    ) -> ScreenWindow {
        ScreenWindow(
            windowID: id, frame: CGRect(x: 0, y: 0, width: w, height: 300),
            bundleID: bundle, pid: pid, title: title)
    }

    @Test func largestPreferredWindowWins() {
        let windows = [
            win(400, bundle: "us.zoom.xos", pid: 1, id: 10),
            win(800, bundle: "us.zoom.xos", pid: 1, id: 11),
            win(900, bundle: "com.apple.Safari", pid: 2, id: 12),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 2)
        #expect(picked?.windowID == 11)
    }

    @Test func fallsBackToFrontmostWhenNoPreferred() {
        let windows = [
            win(400, bundle: "com.apple.Safari", pid: 2, id: 20),
            win(800, bundle: "com.apple.Notes", pid: 3, id: 21),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 3)
        #expect(picked?.windowID == 21)
    }

    @Test func nilWhenNeitherPreferredNorFrontmost() {
        let windows = [win(400, bundle: "com.apple.Safari", pid: 2, id: 30)]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 9)
        #expect(picked == nil)
    }

    // The regression behind "everyone became Speaker": the Teams *main* window (or a
    // big browser window — browsers are in Teams' preferred set) is larger than the
    // actual meeting window, so size-only selection captures the wrong window and
    // OCR never sees a name. The meeting window is the one whose title carries the
    // calendar subject, so a title match must beat raw size.

    @Test func titleMatchBeatsLargerMainWindow() {
        let windows = [
            win(
                1600, bundle: "com.microsoft.teams2", pid: 1, id: 40,
                title: "Chat | Microsoft Teams"),
            win(
                900, bundle: "com.microsoft.teams2", pid: 1, id: 41,
                title: "ANZ/Hashicorp ADP Fortnightly catchup | Microsoft Teams"),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows,
            preferredBundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"],
            frontmostPID: nil,
            meetingTitle: "ANZ/Hashicorp ADP Fortnightly catchup")
        #expect(picked?.windowID == 41)
    }

    @Test func titleMatchBeatsLargerBrowserWindow() {
        let windows = [
            win(
                1900, bundle: "com.google.Chrome", pid: 2, id: 50,
                title: "some-repo: pull requests - Google Chrome"),
            win(
                900, bundle: "com.microsoft.teams2", pid: 1, id: 51,
                title: "A/NZ TFO Weekly | Microsoft Teams"),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows,
            preferredBundleIDs: ["com.microsoft.teams2", "com.google.Chrome"],
            frontmostPID: nil,
            meetingTitle: "A/NZ TFO Weekly")
        #expect(picked?.windowID == 51)
    }

    @Test func titleMatchIsCaseInsensitive() {
        let windows = [
            win(1600, bundle: "us.zoom.xos", pid: 1, id: 60, title: "Zoom Workplace"),
            win(900, bundle: "us.zoom.xos", pid: 1, id: 61, title: "weekly SYNC - Zoom"),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: nil,
            meetingTitle: "Weekly Sync")
        #expect(picked?.windowID == 61)
    }

    @Test func fallsBackToLargestPreferredWhenNoTitleMatches() {
        let windows = [
            win(
                1600, bundle: "com.microsoft.teams2", pid: 1, id: 70,
                title: "Chat | Microsoft Teams"),
            win(900, bundle: "com.microsoft.teams2", pid: 1, id: 71, title: nil),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows,
            preferredBundleIDs: ["com.microsoft.teams2"],
            frontmostPID: nil,
            meetingTitle: "Totally Different Meeting")
        #expect(picked?.windowID == 70)
    }

    @Test func blankMeetingTitleIsIgnored() {
        let windows = [
            win(1600, bundle: "com.microsoft.teams2", pid: 1, id: 80, title: "Big"),
            win(900, bundle: "com.microsoft.teams2", pid: 1, id: 81, title: "Small"),
        ]
        for title in [nil, "", "  "] as [String?] {
            let picked = DisplaySelector.pickWindow(
                windows: windows, preferredBundleIDs: ["com.microsoft.teams2"],
                frontmostPID: nil, meetingTitle: title)
            #expect(picked?.windowID == 80)
        }
    }

    @Test func titleMatchOnlyAppliesToPreferredWindows() {
        // A stray non-meeting window (calendar, email, this app's own UI) can carry
        // the meeting subject in its title; it must never be captured.
        let windows = [
            win(900, bundle: "com.apple.Notes", pid: 3, id: 90, title: "Weekly Sync notes"),
            win(400, bundle: "us.zoom.xos", pid: 1, id: 91, title: "Zoom Workplace"),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: nil,
            meetingTitle: "Weekly Sync")
        #expect(picked?.windowID == 91)
    }
}
