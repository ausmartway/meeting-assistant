import Foundation
import AppKit

/// Confirms that the meeting for a calendared event is actually live before the
/// app prompts the user to record it. The trigger is "calendar AND app detected":
/// a meeting is on the calendar *and* the relevant client is running.
///
/// Detection is intentionally conservative — when it can't confirm, no prompt is
/// posted and the user can still start capture manually from the menu bar.
public final class MeetingDetector {

    /// Bundle identifiers / process names that indicate each provider is running.
    private static let zoomBundleIDs = ["us.zoom.xos"]
    private static let browserBundleIDs = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
    ]
    private static let teamsBundleIDs = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
    ]
    private static let webexBundleIDs = [
        "com.cisco.webexmeetings",   // Cisco Webex Meetings
        "Cisco-Systems.Spark",       // Webex (suite) app
    ]

    public init() {}

    /// Whether the client for `provider` appears to be running right now.
    public func isMeetingAppRunning(for provider: MeetingProvider) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        switch provider {
        case .zoom:
            return !running.isDisjoint(with: Self.zoomBundleIDs)
        case .microsoftTeams:
            // Teams has a native client; it also runs in browsers.
            return !running.isDisjoint(with: Self.teamsBundleIDs)
                || !running.isDisjoint(with: Self.browserBundleIDs)
        case .googleMeet:
            // Meet is browser-only.
            return !running.isDisjoint(with: Self.browserBundleIDs)
        case .webex:
            // Webex has a native client; it also runs in browsers.
            return !running.isDisjoint(with: Self.webexBundleIDs)
                || !running.isDisjoint(with: Self.browserBundleIDs)
        }
    }

    /// Whether `meeting` is happening right now — started within `grace` of its
    /// start and not yet ended — regardless of whether its client app is running.
    /// Lets a manual "Record now" attach to a calendar meeting in progress (using
    /// its real subject) instead of creating a generic ad-hoc entry.
    public func isInProgress(_ meeting: Meeting, now: Date = Date(), grace: TimeInterval = 300) -> Bool {
        Self.isWithinWindow(meeting, now: now, grace: grace)
    }

    /// True when both conditions for prompting the user hold: the meeting has
    /// started (within a small grace window) and its client is running. (The name
    /// is retained for stability; it now gates a prompt, not an automatic start.)
    public func shouldAutoStart(_ meeting: Meeting, now: Date = Date(), grace: TimeInterval = 120) -> Bool {
        guard let provider = meeting.provider else { return false }
        return Self.isWithinWindow(meeting, now: now, grace: grace)
            && isMeetingAppRunning(for: provider)
    }

    /// Pure time-window half of the detection decision: the meeting has started
    /// (within `grace` seconds before its start time) and has not yet ended.
    /// Separated from the `NSWorkspace` running-app check so the prompt timing
    /// — the app's headline behavior — is unit-testable.
    static func isWithinWindow(_ meeting: Meeting, now: Date, grace: TimeInterval) -> Bool {
        now >= meeting.startDate.addingTimeInterval(-grace) && now < meeting.endDate
    }
}
