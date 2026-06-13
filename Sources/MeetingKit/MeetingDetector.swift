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

    /// True when both conditions for auto-start hold: the meeting has started
    /// (within a small grace window) and its client is running.
    public func shouldAutoStart(_ meeting: Meeting, now: Date = Date(), grace: TimeInterval = 120) -> Bool {
        guard let provider = meeting.provider else { return false }
        let started = now >= meeting.startDate.addingTimeInterval(-grace)
        let notEndedYet = now < meeting.endDate
        return started && notEndedYet && isMeetingAppRunning(for: provider)
    }
}
