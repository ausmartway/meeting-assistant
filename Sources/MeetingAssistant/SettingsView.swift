import SwiftUI
import MeetingKit

/// Settings: permissions status + re-grant, and transcription model selection.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock.shield") }
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 460, height: 360)
        .task { await state.permissions.refresh() }
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        let p = state.permissions
        return Form {
            permissionRow("Screen & System Audio", p.screenRecording) { p.requestScreenRecording() }
            permissionRow("Microphone", p.microphone) { Task { await p.requestMicrophone() } }
            permissionRow("Calendar", p.calendar) { Task { await p.requestCalendar(); state.refreshUpcoming() } }
            permissionRow("Accessibility", p.accessibility) { p.requestAccessibility() }
            permissionRow("Notifications", p.notifications) { Task { await p.requestNotifications() } }

            Text("Unsigned/development builds may require adding the app manually under System Settings → Privacy & Security.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func permissionRow(_ name: String, _ stateValue: PermissionState, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: stateValue.symbol)
                .foregroundStyle(stateValue == .granted ? .green : (stateValue == .denied ? .red : .secondary))
            Text(name)
            Spacer()
            if stateValue != .granted {
                Button("Grant", action: action)
            }
        }
    }

    // MARK: - Models

    private var modelsTab: some View {
        Form {
            Picker("Transcription model", selection: Binding(
                get: { state.settings.transcriptionModel },
                set: { state.settings.transcriptionModel = $0 }
            )) {
                ForEach(TranscriptionModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .onChange(of: state.settings.transcriptionModel) {
                // Changing the model triggers a fresh download/load.
                Task { await state.prepareModel() }
            }

            LabeledContent("Model status") {
                if state.modelPreparing {
                    Text(state.modelStatusText ?? "Preparing…")
                } else if state.modelReady {
                    Label("Ready", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else {
                    Button("Download / retry") { Task { await state.prepareModel() } }
                }
            }

            Text("Transcription runs 100% on-device. Audio never leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
