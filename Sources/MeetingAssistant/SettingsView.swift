import SwiftUI
import MeetingKit

/// Settings: permissions status + re-grant, and transcription model selection.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock.shield") }
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 460, height: 360)
        .task { await state.permissions.refresh() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Show icon in the Dock", isOn: Binding(
                get: { state.settings.showDockIcon },
                set: { state.settings.showDockIcon = $0 }
            ))
            .onChange(of: state.settings.showDockIcon) {
                state.applyDockIconSetting()
            }
            Text("Adds a Dock icon so you can always open Meeting Assistant — handy "
                 + "when the menu-bar icon is hidden because the menu bar is full "
                 + "(for example on a laptop screen with a notch).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        // Drive these rows from the same SetupCapability source as onboarding so the
        // names match exactly across both screens.
        Form {
            ForEach(SetupCapability.allCases, id: \.self) { permissionRow($0) }

            Text("If a switch won't turn on, open System Settings → Privacy & Security and enable Meeting Assistant there.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func permissionRow(_ capability: SetupCapability) -> some View {
        let status = state.setup.status(capability)
        return HStack {
            Image(systemName: symbol(for: status))
                .foregroundStyle(status == .granted ? .green : (status == .denied ? .red : .secondary))
            Text(capability.title)
            if !capability.isRequired {
                Text("Optional").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if status != .granted {
                Button(capability.requiresSystemSettings ? "Open System Settings" : "Grant") {
                    Task { await state.grant(capability) }
                }
            }
        }
    }

    private func symbol(for status: SetupPermissionStatus) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        }
    }

    // MARK: - Models

    private var modelsTab: some View {
        Form {
            // The everyday view: just whether transcription is ready. No model
            // jargon or tuning knobs — sensible defaults are chosen for the user.
            LabeledContent("Transcription") {
                if state.modelPreparing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(state.modelStatusText ?? "Preparing…")
                    }
                } else if state.modelReady {
                    Label("Ready", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else if state.modelFailed {
                    Button("Retry download") { Task { await state.prepareModel() } }
                } else {
                    Button("Download") { Task { await state.prepareModel() } }
                }
            }

            if state.modelFailed, let status = state.modelStatusText {
                Text(status).font(.caption).foregroundStyle(.orange)
            }

            Text("Transcription runs 100% on your Mac. Audio never leaves this computer.")
                .font(.caption).foregroundStyle(.secondary)

            // Power-user options, collapsed by default so they don't add noise.
            DisclosureGroup("Advanced") {
                Picker("Quality", selection: Binding(
                    get: { state.settings.transcriptionModel },
                    set: { state.settings.transcriptionModel = $0 }
                )) {
                    ForEach(TranscriptionModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: state.settings.transcriptionModel) {
                    // Switching quality downloads a different model.
                    Task { await state.prepareModel() }
                }
                Text("Higher quality is more accurate but downloads a larger model "
                     + "(up to ~1.6 GB) and transcribes a little slower.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
