import Foundation

/// The state of a single macOS permission, mirrored here in pure (UI-free,
/// framework-free) form so the onboarding logic can be unit-tested.
public enum SetupPermissionStatus: Sendable, Equatable {
    case granted, denied, notDetermined
}

/// A capability the app asks the user to enable during first-run setup. Each
/// carries plain-English copy and whether it is *required* for the core job
/// (auto-record a meeting and produce a transcript) versus merely recommended.
public enum SetupCapability: String, CaseIterable, Sendable {
    case screenRecording
    case microphone
    case calendar
    case accessibility
    case notifications

    /// Short, human title shown in the checklist.
    public var title: String {
        switch self {
        case .screenRecording: return "Screen & Audio Recording"
        case .microphone: return "Microphone"
        case .calendar: return "Calendar"
        case .accessibility: return "Window Detection"
        case .notifications: return "Notifications"
        }
    }

    /// One plain-English sentence explaining *why* the app needs it — no jargon.
    public var purpose: String {
        switch self {
        case .screenRecording: return "Records what the other people say during the meeting."
        case .microphone: return "Records your own voice during the meeting."
        case .calendar: return "Lets the app start recording automatically when a meeting begins."
        case .accessibility: return "Helps label who said what by reading on-screen names."
        case .notifications: return "Tells you when recording starts and your transcript is ready."
        }
    }

    /// Whether the app's core job is impossible without this. The three required
    /// capabilities make automatic recording + transcription work; the other two
    /// only improve the result and are safe to skip.
    public var isRequired: Bool {
        switch self {
        case .screenRecording, .microphone, .calendar: return true
        case .accessibility, .notifications: return false
        }
    }

    /// macOS has no in-app grant for these — the user must flip a switch in
    /// System Settings and come back. Onboarding must say so, or the user clicks
    /// "Turn On" and nothing visibly happens.
    public var requiresSystemSettings: Bool {
        switch self {
        case .screenRecording, .accessibility: return true
        case .microphone, .calendar, .notifications: return false
        }
    }

    /// Guidance shown while the capability is still off — tells the user where the
    /// switch actually lives when it isn't a simple in-app prompt.
    public var grantHint: String? {
        requiresSystemSettings
            ? "Click, then enable Meeting Assistant in System Settings and return here."
            : nil
    }
}

/// Pure summary of where the user is in first-run setup, derived only from the
/// permission statuses. Drives the onboarding checklist and the "setup
/// incomplete" prompts without touching any UI or system framework.
public struct SetupState: Sendable {
    public let statuses: [SetupCapability: SetupPermissionStatus]

    public init(statuses: [SetupCapability: SetupPermissionStatus]) {
        self.statuses = statuses
    }

    public func status(_ capability: SetupCapability) -> SetupPermissionStatus {
        statuses[capability] ?? .notDetermined
    }

    /// Required capabilities not yet granted, in canonical (display) order.
    public var outstandingRequired: [SetupCapability] {
        SetupCapability.allCases.filter { $0.isRequired && status($0) != .granted }
    }

    /// True once every *required* capability is granted. Optional ones (window
    /// detection, notifications) never block completion.
    public var isComplete: Bool { outstandingRequired.isEmpty }

    /// The single next thing to ask the user for — the first required capability
    /// still outstanding.
    public var nextStep: SetupCapability? { outstandingRequired.first }

    /// Short plain-English headline describing the current setup state.
    public var headline: String {
        let remaining = outstandingRequired.count
        switch remaining {
        case 0:  return "You're all set — meetings will record automatically."
        case 1:  return "One quick step to start recording your meetings."
        default: return "\(remaining) quick steps to start recording your meetings."
        }
    }
}
