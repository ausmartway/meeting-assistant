import MeetingKit
import SwiftUI

/// Settings: permissions status + re-grant, and transcription model selection.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            speakersTab.tabItem { Label("Speakers", systemImage: "person.2.wave.2") }
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock.shield") }
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
            storageTab.tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 460, height: 360)
        .task { await state.permissions.refresh() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle(
                "Show icon in the Dock",
                isOn: Binding(
                    get: { state.settings.showDockIcon },
                    set: { state.settings.showDockIcon = $0 }
                )
            )
            .onChange(of: state.settings.showDockIcon) {
                state.applyDockIconSetting()
            }
            Text(
                "Keeps a Dock icon so you can always open Meeting Assistant — even "
                    + "when the menu-bar icon is hidden because the menu bar is full "
                    + "(for example on a laptop screen with a notch). Turn off for a "
                    + "menu-bar-only app."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Speakers (in-room diarization)

    private var speakersTab: some View {
        Form {
            Section("Your name") {
                TextField(
                    "Display name",
                    text: Binding(
                        get: { state.settings.localUserName },
                        set: { state.settings.localUserName = $0 }
                    )
                )
                .onSubmit { state.applyLocalUserName() }
                Text(
                    "Used instead of \u{201C}Me\u{201D} in new transcripts. Defaults to your Mac account name; already-made transcripts keep their labels."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("In-room speakers") {
                Toggle(
                    "Identify multiple in-room speakers",
                    isOn: Binding(
                        get: { state.settings.identifyInRoomSpeakers },
                        set: { state.settings.identifyInRoomSpeakers = $0 }
                    ))
                Text(
                    "When several people share a room, separate each voice instead "
                        + "of labeling everyone \u{2018}Me\u{2019}."
                )
                .font(.caption).foregroundStyle(.secondary)

                // Gentle hint (not a hard block): without an enrolled voiceprint the
                // diarizer can't tell which voice is the local user.
                if state.settings.identifyInRoomSpeakers && !state.settings.isEnrolled {
                    Label(
                        "Record your voice below so your own speech can be told apart.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Your voice") {
                EnrollmentRow()
                    .environmentObject(state)
            }

            Section("Known speakers") {
                let speakers = state.knownSpeakers()
                if speakers.isEmpty {
                    Text(
                        "No voices learned yet. People you meet are added "
                            + "automatically once in-room identification is on."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(speakers) { speaker in
                        SpeakerRow(speaker: speaker)
                            .environmentObject(state)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        // Drive these rows from the same SetupCapability source as onboarding so the
        // names match exactly across both screens.
        Form {
            ForEach(SetupCapability.allCases, id: \.self) { permissionRow($0) }

            Text(
                "If a switch won't turn on, open System Settings → Privacy & Security and enable Meeting Assistant there."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func permissionRow(_ capability: SetupCapability) -> some View {
        let status = state.setup.status(capability)
        return HStack {
            Image(systemName: symbol(for: status))
                .foregroundStyle(
                    status == .granted ? .green : (status == .denied ? .red : .secondary))
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
                Picker(
                    "Quality",
                    selection: Binding(
                        get: { state.settings.transcriptionModel },
                        set: { state.settings.transcriptionModel = $0 }
                    )
                ) {
                    ForEach(TranscriptionModel.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .onChange(of: state.settings.transcriptionModel) {
                    // Switching quality downloads a different model.
                    Task { await state.prepareModel() }
                }
                Text(
                    "Higher quality is more accurate but downloads a larger model "
                        + "(up to ~1.6 GB) and transcribes a little slower."
                )
                .font(.caption).foregroundStyle(.secondary)

                Picker(
                    "Engine",
                    selection: Binding(
                        get: { state.settings.transcriptionEngine },
                        set: { state.settings.transcriptionEngine = $0 }
                    )
                ) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .onChange(of: state.settings.transcriptionEngine) {
                    // Switching engines loads a different model.
                    Task { await state.prepareModel() }
                }
                Text(
                    "Automatic uses fast Parakeet for English/European speech and "
                        + "WhisperKit for Mandarin and other languages. Pick a specific "
                        + "engine to override."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Storage (retention)

    // Offered retention windows; 0 == "Never".
    private let mediaWindows: [(label: String, days: Int)] =
        [("3 days", 3), ("7 days", 7), ("14 days", 14), ("30 days", 30), ("Never", 0)]
    private let transcriptWindows: [(label: String, days: Int)] =
        [("90 days", 90), ("180 days", 180), ("1 year", 365), ("Never", 0)]

    private var storageTab: some View {
        Form {
            Section("Space used") {
                HStack {
                    Text("All recordings")
                    Spacer()
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: state.storageBytes, countStyle: .file)
                    )
                    .foregroundStyle(.secondary)
                }
                Button("Clean up now") { state.cleanUpStorageNow() }
            }
            Section("Keep audio for") {
                Picker(
                    "Audio",
                    selection: Binding(
                        get: { state.settings.mediaRetentionDays },
                        set: { state.settings.mediaRetentionDays = $0 }
                    )
                ) {
                    ForEach(mediaWindows, id: \.days) { Text($0.label).tag($0.days) }
                }
                .onChange(of: state.settings.mediaRetentionDays) { _, _ in
                    state.runRetentionSweep()
                }
                Text(
                    "Recordings are large. Their audio is deleted automatically after "
                        + "this long to free space; the transcript is kept."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keep transcripts for") {
                Picker(
                    "Transcripts",
                    selection: Binding(
                        get: { state.settings.transcriptRetentionDays },
                        set: { state.settings.transcriptRetentionDays = $0 }
                    )
                ) {
                    ForEach(transcriptWindows, id: \.days) { Text($0.label).tag($0.days) }
                }
                .onChange(of: state.settings.transcriptRetentionDays) { _, _ in
                    state.runRetentionSweep()
                }
                Text("Transcripts are tiny, so they can be kept much longer than the audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { state.refreshStorageTotal() }
    }
}

// MARK: - Voice enrollment row

/// Reads the enrollment script aloud and records a short voiceprint clip for "Me".
/// Kept as its own view so the recorder is an `@StateObject` with its own lifecycle.
private struct EnrollmentRow: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var enroller = EnrollmentRecorder()
    @State private var showScript = false
    @State private var enrollmentFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if state.settings.isEnrolled {
                    Label("Your voice is enrolled", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    Text("Your voice is not enrolled yet.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if enroller.isRecording {
                    Button("Stop") { enroller.stop() }
                } else if state.isEnrolling {
                    ProgressView().controlSize(.small)
                } else {
                    Button(state.settings.isEnrolled ? "Re-record" : "Record my voice") {
                        enrollmentFailed = false
                        showScript = true
                        startRecording()
                    }
                }
            }

            if showScript || enroller.isRecording {
                Text(EnrollmentScript.passage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if enroller.isRecording {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Recording… read the passage above in your normal voice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if state.isEnrolling {
                Text(state.modelStatusText ?? "Processing your voice…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if enrollmentFailed {
                Text("That recording didn't work. Please try again in a quiet spot.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-\(UUID().uuidString).wav")
        enroller.record(to: url) { result in
            if case .success(let recorded) = result {
                Task {
                    let ok = await state.enrollMe(audioFile: recorded)
                    enrollmentFailed = !ok
                    showScript = false
                    try? FileManager.default.removeItem(at: recorded)
                }
            } else {
                enrollmentFailed = true
                showScript = false
            }
        }
    }
}

// MARK: - Known-speaker row (rename / delete)

/// One row in the speaker library: an editable name plus a delete button. The local
/// user ("Me") is marked and never deletable.
private struct SpeakerRow: View {
    @EnvironmentObject private var state: AppState
    let speaker: KnownSpeaker
    @State private var draft: String

    init(speaker: KnownSpeaker) {
        self.speaker = speaker
        _draft = State(initialValue: speaker.name)
    }

    var body: some View {
        HStack {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .disabled(speaker.isMe)
            if speaker.isMe {
                Text("Me").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !speaker.isMe {
                Button(role: .destructive) {
                    state.deleteKnownSpeaker(id: speaker.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != speaker.name else { return }
        state.renameKnownSpeaker(id: speaker.id, to: trimmed)
    }
}
