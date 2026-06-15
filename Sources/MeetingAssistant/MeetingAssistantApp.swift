import SwiftUI

/// App entry point. A menu-bar presence for status and quick control, plus a
/// regular window for browsing transcripts and managing settings.
@main
struct MeetingAssistantApp: App {
    @StateObject private var state = AppState()

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
                .frame(minWidth: 720, minHeight: 460)
                .task {
                    await state.permissions.refresh()
                    state.start()
                }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
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
                guard !state.hasAutoOpenedWindow else { return }
                state.hasAutoOpenedWindow = true
                openWindow(id: "main")
            }
    }
}
