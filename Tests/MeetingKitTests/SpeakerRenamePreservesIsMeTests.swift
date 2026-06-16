import Testing
import Foundation
@testable import MeetingKit

/// The most consequential invariant of the rename → relearn flow: renaming a
/// meeting speaker must never silently demote the enrolled "Me" or change an
/// existing person's enrolled-ness. Covers the pure decision
/// `KnownSpeaker.preservedIsMe` that `AppState.renameSpeaker` relies on.
@Suite("KnownSpeaker.preservedIsMe")
struct SpeakerRenamePreservesIsMeTests {

    private let library = [
        KnownSpeaker(name: "Me", isMe: true, embedding: [1, 0, 0]),
        KnownSpeaker(name: "Sam", isMe: false, embedding: [0, 1, 0]),
    ]

    @Test("renaming a cluster to the enrolled user keeps isMe true")
    func toMeKeepsEnrollment() {
        #expect(KnownSpeaker.preservedIsMe(forName: "Me", in: library) == true)
    }

    @Test("the match is case-insensitive")
    func caseInsensitive() {
        #expect(KnownSpeaker.preservedIsMe(forName: "me", in: library) == true)
    }

    @Test("renaming to an existing non-me speaker stays not-me")
    func existingOtherStaysNotMe() {
        #expect(KnownSpeaker.preservedIsMe(forName: "Sam", in: library) == false)
    }

    @Test("a brand-new name is never the enrolled user")
    func brandNewIsNotMe() {
        #expect(KnownSpeaker.preservedIsMe(forName: "Dana", in: library) == false)
    }
}
