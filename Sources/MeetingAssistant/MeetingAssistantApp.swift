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
            Image(systemName: menuBarSymbol)
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

    private var menuBarSymbol: String {
        switch state.status {
        case .idle: return "waveform"
        case .recording: return "record.circle"
        case .processing: return "gearshape.2"
        }
    }
}
