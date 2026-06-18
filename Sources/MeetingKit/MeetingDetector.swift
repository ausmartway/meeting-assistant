import AppKit
import Foundation

/// Confirms that the meeting for a calendared event is actually live before the
/// app prompts the user to record it. The trigger is "calendar AND app detected":
/// a meeting is on the calendar *and* the relevant client is running.
///
/// Detection is intentionally conservative — when it can't confirm, no prompt is
/// posted and the user can still start capture manually from the menu bar.
public final class MeetingDetector {

    public init() {}

    /// Whether the client for `provider` appears to be running right now.
    public func isMeetingAppRunning(for provider: MeetingProvider) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !running.isDisjoint(with: provider.meetingAppBundleIDs)
    }

    /// Whether `meeting` is happening right now — started within `grace` of its
    /// start and not yet ended — regardless of whether its client app is running.
    /// Lets a manual "Record now" attach to a calendar meeting in progress (using
    /// its real subject) instead of creating a generic ad-hoc entry.
    public func isInProgress(_ meeting: Meeting, now: Date = Date(), grace: TimeInterval = 300)
        -> Bool
    {
        Self.isWithinWindow(meeting, now: now, grace: grace)
    }

    /// True when both conditions for prompting the user hold: the meeting has
    /// started (within a small grace window) and its client is running. (The name
    /// is retained for stability; it now gates a prompt, not an automatic start.)
    public func shouldAutoStart(_ meeting: Meeting, now: Date = Date(), grace: TimeInterval = 120)
        -> Bool
    {
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
