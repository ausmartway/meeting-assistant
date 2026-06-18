import Testing
import Foundation
@testable import MeetingKit

@Suite struct RetentionPolicyTests {
    // A fixed clock so tests are deterministic.
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func expiresMediaPastWindow() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldExpireMedia(recordedAt: daysAgo(8), now: now) == true)
    }

    @Test func keepsMediaWithinWindow() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldExpireMedia(recordedAt: daysAgo(6), now: now) == false)
    }

    @Test func neverExpiresMediaWhenNil() {
        let p = RetentionPolicy(mediaMaxAge: nil, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldExpireMedia(recordedAt: daysAgo(999), now: now) == false)
    }

    @Test func deletesBundlePastTranscriptWindow() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldDeleteBundle(recordedAt: daysAgo(366), now: now) == true)
        #expect(p.shouldDeleteBundle(recordedAt: daysAgo(364), now: now) == false)
    }

    @Test func neverDeletesBundleWhenNil() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: nil)
        #expect(p.shouldDeleteBundle(recordedAt: daysAgo(99_999), now: now) == false)
    }

    @Test func defaultIsSevenDaysAndOneYear() {
        #expect(RetentionPolicy.default.mediaMaxAge == 7 * 86_400.0)
        #expect(RetentionPolicy.default.transcriptMaxAge == 365 * 86_400.0)
    }
}
