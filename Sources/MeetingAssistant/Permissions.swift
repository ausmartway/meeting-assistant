import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import EventKit
import UserNotifications
import MeetingKit

/// Status of a single permission, for the onboarding/settings UI.
enum PermissionState {
    case granted, denied, notDetermined

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        }
    }
}

/// Centralizes the macOS permission checks and prompts the app needs:
/// Screen Recording (system audio + frames), Microphone, Calendar,
/// Accessibility (window detection), and Notifications.
@MainActor
final class Permissions: ObservableObject {
    @Published var screenRecording: PermissionState = .notDetermined
    @Published var microphone: PermissionState = .notDetermined
    @Published var calendar: PermissionState = .notDetermined
    @Published var accessibility: PermissionState = .notDetermined
    @Published var notifications: PermissionState = .notDetermined

    private let calendarWatcher: CalendarWatcher

    init(calendarWatcher: CalendarWatcher) {
        self.calendarWatcher = calendarWatcher
    }

    func refresh() async {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        microphone = map(AVCaptureDevice.authorizationStatus(for: .audio))
        calendar = mapCalendar(calendarWatcher.authorizationStatus)
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: notifications = .granted
        case .denied: notifications = .denied
        default: notifications = .notDetermined
        }
    }

    // MARK: - Requests

    func requestScreenRecording() {
        // Triggers the system prompt; the user may need to add the app manually
        // for unsigned/dev builds (see onboarding copy).
        _ = CGRequestScreenCaptureAccess()
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    func requestCalendar() async {
        let granted = await calendarWatcher.requestAccess()
        calendar = granted ? .granted : .denied
    }

    func requestAccessibility() {
        // There is no programmatic grant; prompt the user to the pane.
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        accessibility = AXIsProcessTrustedWithOptions(options as CFDictionary) ? .granted : .notDetermined
    }

    func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        notifications = granted ? .granted : .denied
    }

    // MARK: - Mapping helpers

    private func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func mapCalendar(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        default: return .notDetermined
        }
    }
}
