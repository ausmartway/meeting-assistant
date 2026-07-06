import Foundation
import Testing

@testable import MeetingKit

/// EventKit returns the *same* `eventIdentifier` for every occurrence of a
/// recurring event. Recordings are stored in a directory derived from
/// `Meeting.id`, so occurrences must get distinct ids or a later occurrence
/// silently overwrites the earlier recording (the "A/NZ TFO Weekly" bug).
@Suite("Meeting.occurrenceID")
struct MeetingOccurrenceIDTests {

    let eventID = "143978AC-F601-4692-9936-8DC213C444BC:7682E75D-9126-4FF1-8CBA-BAF23FBC0247"

    @Test func differentOccurrencesGetDifferentIDs() {
        let june29 = Date(timeIntervalSince1970: 1_782_004_200)
        let july6 = june29.addingTimeInterval(7 * 24 * 60 * 60)
        let a = Meeting.occurrenceID(eventIdentifier: eventID, startDate: june29)
        let b = Meeting.occurrenceID(eventIdentifier: eventID, startDate: july6)
        #expect(a != b)
    }

    @Test func sameOccurrenceIsStableAcrossRefreshes() {
        // The calendar watcher rebuilds Meetings on every refresh; the id must not
        // drift or notification → meeting matching (and prompt dedupe) breaks.
        let start = Date(timeIntervalSince1970: 1_782_004_200)
        let a = Meeting.occurrenceID(eventIdentifier: eventID, startDate: start)
        let b = Meeting.occurrenceID(eventIdentifier: eventID, startDate: start)
        #expect(a == b)
    }

    @Test func idEmbedsTheEventIdentifier() {
        // Keeps bundles on disk traceable back to their calendar event.
        let id = Meeting.occurrenceID(
            eventIdentifier: eventID, startDate: Date(timeIntervalSince1970: 0))
        #expect(id.hasPrefix(eventID))
    }

    @Test func subSecondJitterDoesNotChangeTheID() {
        // EventKit start dates are whole seconds, but guard against any
        // floating-point jitter producing a "new" occurrence.
        let start = Date(timeIntervalSince1970: 1_782_004_200)
        let jittered = Date(timeIntervalSince1970: 1_782_004_200.4)
        let a = Meeting.occurrenceID(eventIdentifier: eventID, startDate: start)
        let b = Meeting.occurrenceID(eventIdentifier: eventID, startDate: jittered)
        #expect(a == b)
    }
}
