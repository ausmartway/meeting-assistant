import SwiftUI
import AppKit
import MeetingKit

/// Main window: a sidebar list of past meetings and a detail pane showing the
/// speaker-labeled transcript.
struct MainWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?
    @State private var pendingDelete: MeetingRecording?

    var body: some View {
        Group {
            if !state.setup.isComplete {
                // First-run: walk the user through permissions before anything else.
                OnboardingView()
            } else {
                meetingsSplitView
            }
        }
        .overlay(alignment: .top) {
            if state.modelPreparing {
                HStack(spacing: 10) {
                    if let f = state.modelDownloadFraction {
                        ProgressView(value: f).frame(width: 140)
                        Text("\(state.modelStatusText ?? "Preparing model…") \(Int(f * 100))%")
                    } else {
                        ProgressView().controlSize(.small)
                        Text(state.modelStatusText ?? "Preparing model…")
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = state.lastError {
                HStack(alignment: .top, spacing: 10) {
                    Text(error)
                        .font(.callout).foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    Button {
                        state.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12).background(.red, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 440)
                .padding()
                // Auto-dismiss so a stale banner doesn't linger if the user moves on.
                .task(id: error) {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    state.dismissError()
                }
            }
        }
    }

    /// The transcripts browser, shown once setup is complete.
    private var meetingsSplitView: some View {
        NavigationSplitView {
            List(state.recordings, id: \.meeting.id, selection: $selection) { recording in
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.meeting.title).font(.body)
                    Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(recording.meeting.id)
                .contextMenu {
                    Button("Delete Meeting", role: .destructive) { pendingDelete = recording }
                }
            }
            .navigationTitle("Meetings")
            .frame(minWidth: 220)
            .confirmationDialog(
                "Delete this meeting?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { recording in
                Button("Delete", role: .destructive) {
                    if selection == recording.meeting.id { selection = nil }
                    state.deleteRecording(recording)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("This permanently deletes the recording and its transcript. This can't be undone.")
            }
        } detail: {
            if state.recordings.isEmpty {
                firstMeetingPrompt
            } else if let id = selection,
                      let recording = state.recordings.first(where: { $0.meeting.id == id }) {
                MeetingDetailView(recording: recording)
            } else {
                ContentUnavailableViewCompat(
                    title: "No meeting selected",
                    systemImage: "doc.text.magnifyingglass",
                    description: "Pick a meeting from the list to see its transcript."
                )
            }
        }
        // A record control in the title bar so recording can be started/stopped
        // with the window open — not only from the menu bar.
        .toolbar {
            ToolbarItem(placement: .primaryAction) { recordControl }
        }
    }

    /// State-aware record control for the window toolbar. Mirrors the menu bar's
    /// Start/Stop so the two stay in lockstep: Record → Stop & Process → progress.
    @ViewBuilder
    private var recordControl: some View {
        switch state.status {
        case .recording:
            Button(role: .destructive) {
                Task { await state.stopCapture() }
            } label: {
                Label("Stop & Process", systemImage: "stop.circle")
            }
            .help("Stop recording and make the transcript")
        case .processing:
            // Non-interactive while post-processing runs; matches the menu bar.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.progressPhase ?? "Processing…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .idle:
            // Recording can begin before the model finishes downloading —
            // capture is independent of it and processing waits — so this stays
            // enabled regardless of model readiness (same as the menu bar).
            Button {
                Task { await state.startAdHocCapture() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .help("Start recording a meeting now")
        }
    }

    /// Shown when there are no recordings yet — a real empty state with a clear
    /// call to action rather than a "pick a meeting" prompt with nothing to pick.
    private var firstMeetingPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No meetings yet").font(.headline)
            Text("Your transcripts will appear here. Calendar meetings record automatically when you join from the Zoom, Teams, or Meet app — or start one now.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                Task { await state.startAdHocCapture() }
            } label: {
                Label("Record a Meeting Now", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.modelReady)
            if !state.modelReady {
                Text("Preparing the transcription model…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Detail pane showing the speaker-labeled transcript.
private struct MeetingDetailView: View {
    @EnvironmentObject private var state: AppState
    let recording: MeetingRecording
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(recording.meeting.title).font(.title2).bold()
                    Text(recording.meeting.provider?.displayName ?? "Meeting")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(alignment: .top, spacing: 8) {
                    let transcript = state.transcript(for: recording)

                    Button {
                        copyToClipboard(transcript ?? "")
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy",
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(transcript == nil)
                    .help("Copy the transcript to the clipboard")
                    // Briefly confirm the copy, then revert the label.
                    .task(id: didCopy) {
                        guard didCopy else { return }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }

                    Menu {
                        Button("Save to File…") {
                            saveToFile(transcript ?? "", suggestedName: recording.meeting.title)
                        }
                        Button("Show in Finder") {
                            let url = state.transcriptURL(for: recording)
                            NSWorkspace.shared.selectFile(
                                url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(transcript == nil)

                    VStack(alignment: .trailing, spacing: 2) {
                        Button {
                            Task { await state.reprocess(recording) }
                        } label: {
                            Label("Make Transcript Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(!state.modelReady)
                        .help("Re-create the transcript from the saved audio")
                        if !state.modelReady {
                            Text("Waiting for the model to finish downloading…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()

            // Live progress while this meeting is being processed.
            if case .processing(let m) = state.status, m.id == recording.meeting.id {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = state.progressFraction {
                        ProgressView(value: fraction) {
                            Text(state.progressPhase ?? "Processing…").font(.caption)
                        }
                        Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(state.progressPhase ?? "Processing…").font(.caption)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            // Speakers section — only shown when the transcript has speaker labels.
            let speakers = state.meetingSpeakers(for: recording)
            if !speakers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speakers")
                        .font(.headline)
                    Text("Rename a speaker to teach the app their voice for next time.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(speakers, id: \.self) { label in
                        SpeakerRenameRow(originalLabel: label) { newName in
                            state.renameSpeaker(in: recording, from: label, to: newName)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                Divider()
            }

            ScrollView { MarkdownText(state.transcript(for: recording) ?? "_No transcript yet._") }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Save the transcript as a Markdown file the user chooses.
    private func saveToFile(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Renders markdown text, falling back to plain text on parse failure.
private struct MarkdownText: View {
    let content: String
    init(_ content: String) { self.content = content }

    var body: some View {
        Text((try? AttributedString(markdown: content,
              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
              ?? AttributedString(content))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
    }
}

/// A single row in the Speakers section: shows the current label with an inline
/// text field so the user can rename it. "Save" is enabled only when the draft
/// is non-empty and differs from the original — avoids no-op writes.
private struct SpeakerRenameRow: View {
    let originalLabel: String
    let onRename: (String) -> Void

    @State private var draft: String

    init(originalLabel: String, onRename: @escaping (String) -> Void) {
        self.originalLabel = originalLabel
        self.onRename = onRename
        _draft = State(initialValue: originalLabel)
    }

    private var canSave: Bool { !draft.isEmpty && draft != originalLabel }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Button {
                onRename(draft)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(canSave ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .help("Save new name")
        }
    }
}

/// Small back-compat wrapper so the empty state renders on the deployment target.
private struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
