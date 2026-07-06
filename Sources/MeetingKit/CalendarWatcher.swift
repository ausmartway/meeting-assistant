import EventKit
import Foundation

/// Reads upcoming meetings from the macOS Calendar (EventKit) and exposes the ones
/// that have a recognized video-conferencing link. Uses `MeetingURLParser` to pull
/// the provider/URL out of each event's fields.
///
/// EventKit surfaces whatever the user has synced into Calendar.app — Google,
/// iCloud, Exchange — so a single permission covers all providers.
public final class CalendarWatcher {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// Request calendar access using the macOS 14+ full-access model.
    public func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Current authorization status, for the onboarding/settings UI.
    public var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Upcoming meetings within `window` from `now` that carry a recognized
    /// conferencing link, sorted by start time.
    public func upcomingMeetings(
        from now: Date = Date(),
        within window: TimeInterval = 24 * 60 * 60
    ) -> [Meeting] {
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(window),
            calendars: nil
        )
        return store.events(matching: predicate)
            .compactMap(Self.meeting(from:))
            .sorted { $0.startDate < $1.startDate }
    }

    /// Convert an `EKEvent` to a `Meeting`, returning nil if it has no meeting link.
    static func meeting(from event: EKEvent) -> Meeting? {
        guard
            let link = MeetingURLParser.parse(
                url: event.url,
                notes: event.notes,
                location: event.location
            )
        else {
            return nil
        }
        return Meeting(
            // Per-occurrence id: eventIdentifier alone is shared by every occurrence
            // of a recurring event, which made occurrences overwrite each other's
            // recording bundles.
            id: Meeting.occurrenceID(
                eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
                startDate: event.startDate),
            title: event.title ?? "Untitled meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            provider: link.provider,
            joinURL: link.url
        )
    }
}
