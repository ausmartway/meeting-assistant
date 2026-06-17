import Foundation

/// Pure helpers for the "meeting detected" actionable notification: the stable
/// category/action identifiers, building the `userInfo` payload from a `Meeting`,
/// and resolving a payload back into a `Meeting` when the user taps Start.
///
/// Kept free of UserNotifications/UI types so the round-trip and the late-click
/// reconstruction are unit-testable without system access.
public enum MeetingNotification {
    /// Category attached to the prompt so its action button is shown.
    public static let categoryID = "MEETING_DETECTED"
    /// The single "Start Recording" action's identifier.
    public static let startActionID = "START_RECORDING"

    private static let idKey = "meetingID"
    private static let titleKey = "meetingTitle"
    private static let providerKey = "meetingProvider"

    /// Encode the bits we need to resume into a notification payload. Provider is
    /// stored as its raw value (omitted when nil) so a late tap can reconstruct an
    /// ad-hoc meeting if the meeting has left the upcoming list.
    public static func userInfo(for meeting: Meeting) -> [String: String] {
        var info: [String: String] = [
            idKey: meeting.id,
            titleKey: meeting.title,
        ]
        if let provider = meeting.provider {
            info[providerKey] = provider.rawValue
        }
        return info
    }

    /// Resolve a tapped notification's payload to a meeting to record.
    /// - Prefers the live meeting still in `upcoming` (keeps real dates/joinURL).
    /// - Falls back to reconstructing an ad-hoc meeting from the payload (a 2h
    ///   window starting at `now`) so a late tap still records.
    /// - Returns nil when the payload has no meeting id (malformed).
    public static func resolve(
        userInfo: [AnyHashable: Any],
        upcoming: [Meeting],
        now: Date
    ) -> Meeting? {
        guard let id = userInfo[idKey] as? String else { return nil }
        if let live = upcoming.first(where: { $0.id == id }) {
            return live
        }
        let title = (userInfo[titleKey] as? String) ?? "Meeting"
        let provider = (userInfo[providerKey] as? String).flatMap(MeetingProvider.init(rawValue:))
        return Meeting(
            id: id,
            title: title,
            startDate: now,
            endDate: now.addingTimeInterval(2 * 60 * 60),
            provider: provider,
            joinURL: nil
        )
    }
}
