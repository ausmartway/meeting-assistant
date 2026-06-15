import Testing
@testable import MeetingKit

@Suite("SetupGuide")
struct SetupGuideTests {

    private func state(_ pairs: [SetupCapability: SetupPermissionStatus]) -> SetupState {
        SetupState(statuses: pairs)
    }

    @Test("required capabilities are the three that make auto-record + transcribe work")
    func requiredSet() {
        let required = SetupCapability.allCases.filter(\.isRequired)
        #expect(Set(required) == [.screenRecording, .microphone, .calendar])
        #expect(SetupCapability.accessibility.isRequired == false)
        #expect(SetupCapability.notifications.isRequired == false)
    }

    @Test("every capability has non-empty, jargon-free copy")
    func copyExists() {
        for c in SetupCapability.allCases {
            #expect(!c.title.isEmpty)
            #expect(!c.purpose.isEmpty)
        }
    }

    @Test("screen recording and accessibility require System Settings; others prompt in-app")
    func systemSettingsCapabilities() {
        #expect(SetupCapability.screenRecording.requiresSystemSettings)
        #expect(SetupCapability.accessibility.requiresSystemSettings)
        #expect(SetupCapability.microphone.requiresSystemSettings == false)
        #expect(SetupCapability.calendar.requiresSystemSettings == false)
        // Capabilities needing System Settings carry a hint; in-app ones don't.
        #expect(SetupCapability.screenRecording.grantHint != nil)
        #expect(SetupCapability.microphone.grantHint == nil)
    }

    @Test("a fresh install (nothing determined) is incomplete with all required outstanding")
    func freshInstall() {
        let s = state([:]) // everything defaults to .notDetermined
        #expect(s.isComplete == false)
        #expect(s.outstandingRequired == [.screenRecording, .microphone, .calendar])
        #expect(s.nextStep == .screenRecording)
    }

    @Test("granting all required completes setup even when optional ones are missing")
    func requiredGrantedIsComplete() {
        let s = state([
            .screenRecording: .granted,
            .microphone: .granted,
            .calendar: .granted,
            .accessibility: .notDetermined,
            .notifications: .denied,
        ])
        #expect(s.isComplete)
        #expect(s.outstandingRequired.isEmpty)
        #expect(s.nextStep == nil)
    }

    @Test("a single missing required capability is the next step")
    func oneMissing() {
        let s = state([
            .screenRecording: .granted,
            .microphone: .granted,
            .calendar: .notDetermined,
        ])
        #expect(s.isComplete == false)
        #expect(s.outstandingRequired == [.calendar])
        #expect(s.nextStep == .calendar)
    }

    @Test("denied counts as outstanding, not granted")
    func deniedIsOutstanding() {
        let s = state([
            .screenRecording: .denied,
            .microphone: .granted,
            .calendar: .granted,
        ])
        #expect(s.isComplete == false)
        #expect(s.outstandingRequired == [.screenRecording])
    }

    @Test("headline is singular/plural/complete as appropriate")
    func headlines() {
        #expect(state([:]).headline.contains("3 quick steps"))
        #expect(state([.screenRecording: .granted, .microphone: .granted]).headline
            .contains("One quick step"))
        let done = state([.screenRecording: .granted, .microphone: .granted, .calendar: .granted])
        #expect(done.headline.contains("all set"))
    }

    @Test("status() falls back to notDetermined for unspecified capabilities")
    func statusFallback() {
        #expect(state([:]).status(.microphone) == .notDetermined)
        #expect(state([.microphone: .granted]).status(.microphone) == .granted)
    }
}
