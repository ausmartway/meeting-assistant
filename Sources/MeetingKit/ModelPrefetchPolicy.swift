import Foundation

/// Decides when the background model prefetch may begin: only once the app
/// holds every *mandatory* permission (Screen & Audio Recording, Microphone,
/// Calendar), and at most once per app session. Pure so the gate is testable;
/// the optional permissions (Accessibility, Notifications) deliberately don't
/// gate downloads — they don't affect whether transcription can run.
public enum ModelPrefetchPolicy {
    public static func shouldStart(
        screenRecording: SetupPermissionStatus,
        microphone: SetupPermissionStatus,
        calendar: SetupPermissionStatus,
        alreadyStarted: Bool
    ) -> Bool {
        !alreadyStarted
            && screenRecording == .granted
            && microphone == .granted
            && calendar == .granted
    }
}
