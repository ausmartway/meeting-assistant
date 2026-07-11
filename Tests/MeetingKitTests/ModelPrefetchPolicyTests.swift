import Testing

@testable import MeetingKit

@Suite("ModelPrefetchPolicy")
struct ModelPrefetchPolicyTests {

    @Test("starts when all three mandatory permissions are granted")
    func allGranted() {
        #expect(
            ModelPrefetchPolicy.shouldStart(
                screenRecording: .granted, microphone: .granted, calendar: .granted,
                alreadyStarted: false))
    }

    @Test("does not start twice")
    func onlyOnce() {
        #expect(
            !ModelPrefetchPolicy.shouldStart(
                screenRecording: .granted, microphone: .granted, calendar: .granted,
                alreadyStarted: true))
    }

    @Test("waits while any mandatory permission is missing")
    func missingPermission() {
        let notYet: [SetupPermissionStatus] = [.denied, .notDetermined]
        for status in notYet {
            #expect(
                !ModelPrefetchPolicy.shouldStart(
                    screenRecording: status, microphone: .granted, calendar: .granted,
                    alreadyStarted: false))
            #expect(
                !ModelPrefetchPolicy.shouldStart(
                    screenRecording: .granted, microphone: status, calendar: .granted,
                    alreadyStarted: false))
            #expect(
                !ModelPrefetchPolicy.shouldStart(
                    screenRecording: .granted, microphone: .granted, calendar: status,
                    alreadyStarted: false))
        }
    }
}
