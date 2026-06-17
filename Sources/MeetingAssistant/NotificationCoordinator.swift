import Foundation
import UserNotifications
import MeetingKit

/// Owns the "meeting detected" notification category and acts as the system's
/// notification delegate. When the user taps **Start Recording**, it resolves the
/// payload and asks `AppState` to begin capture. Registration and delegate
/// callbacks are the only notification-framework wiring in the app.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    /// Weak so the coordinator never keeps the app coordinator alive.
    weak var appState: AppState?

    /// Become the notification delegate and register the actionable category.
    /// Call once at launch. Safe to call before notification permission is granted
    /// — the category just goes unused until a prompt is posted.
    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(
            identifier: MeetingNotification.startActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: MeetingNotification.categoryID,
            actions: [start],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Show the prompt even when the app is frontmost — otherwise a foreground app
    /// would swallow its own "Start recording?" banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping Start Recording lands here. Hop to the main actor, resolve the
    /// payload, and begin capture.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if actionID == MeetingNotification.startActionID {
                appState?.startCaptureFromNotification(userInfo: userInfo)
            }
            completionHandler()
        }
    }
}
