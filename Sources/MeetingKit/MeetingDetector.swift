import Foundation
import AppKit

/// Confirms that the meeting for a calendared event is actually live before the
/// app auto-starts capture. The trigger is "calendar AND app detected": a meeting
/// is on the calendar *and* the relevant client is running.
///
/// Detection is intentionally conservative — when it can't confirm, the app falls
/// back to a notification asking the user to start capture manually.
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
        }
    }

    /// Best guess at which provider is live right now, for ad-hoc captures with no
    /// calendar entry. Prefers the native clients (unambiguous); returns nil when
    /// only a browser is running, since a browser alone doesn't identify Meet vs
    /// Teams vs something else. The capture works regardless — this only labels it.
    public func firstRunningProvider() -> MeetingProvider? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if !running.isDisjoint(with: Self.zoomBundleIDs) { return .zoom }
        if !running.isDisjoint(with: Self.teamsBundleIDs) { return .microsoftTeams }
        return nil
    }

    /// True when both conditions for auto-start hold: the meeting has started
    /// (within a small grace window) and its client is running.
    public func shouldAutoStart(_ meeting: Meeting, now: Date = Date(), grace: TimeInterval = 120) -> Bool {
        guard let provider = meeting.provider else { return false }
        return Self.isWithinWindow(meeting, now: now, grace: grace)
            && isMeetingAppRunning(for: provider)
    }

    /// Pure time-window half of the auto-start decision: the meeting has started
    /// (within `grace` seconds before its start time) and has not yet ended.
    /// Separated from the `NSWorkspace` running-app check so the auto-start timing
    /// — the app's headline behavior — is unit-testable.
    static func isWithinWindow(_ meeting: Meeting, now: Date, grace: TimeInterval) -> Bool {
        now >= meeting.startDate.addingTimeInterval(-grace) && now < meeting.endDate
    }
}
