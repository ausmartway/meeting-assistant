import SwiftUI
import AppKit

/// App entry point. A menu-bar presence for status and quick control, plus a
/// regular window for browsing transcripts and managing settings.
@main
struct MeetingAssistantApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar status + quick actions.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        // Main window: meeting history and detail.
        Window("Meeting Assistant", id: "main") {
            MainWindowView()
                .environmentObject(state)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    await state.permissions.refresh()
                    state.start()
                }
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(state)
                .tint(Theme.accent)
        }
    }
}

/// The menu-bar icon. Lives in its own view so it can observe `AppState` (the
/// icon changes with status) and open the main window once at first launch —
/// otherwise a brand-new user, faced with a menu-bar-only app, sees nothing.
private struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.menuBarSymbol)
            .onAppear {
                // Expose the window-opening action to non-view code (Dock click /
                // app reopen) so a hidden menu-bar icon never strands the user.
                state.openMainWindow = { openWindow(id: "main") }
                guard !state.hasAutoOpenedWindow else { return }
                state.hasAutoOpenedWindow = true
                openWindow(id: "main")
            }
    }
}

/// Brings the main window forward when the user reopens the app — e.g. clicks the
/// Dock icon, or launches it again from Spotlight/Finder while it's running. This
/// is the reliable way back in when the menu-bar icon is hidden for lack of space.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            AppState.shared?.openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
