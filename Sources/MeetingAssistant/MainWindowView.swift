import SwiftUI
import AppKit
import MeetingKit

/// Main window: a native translucent sidebar of meetings and a detail pane showing
/// the speaker-labeled transcript. Elegant, native-macOS styling (see `Theme`).
struct MainWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?
    @State private var pendingDelete: MeetingRecording?

    var body: some View {
        Group {
            if !state.setup.isComplete {
                OnboardingView()
            } else {
                meetingsSplitView
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) { modelBanner }
        .overlay(alignment: .bottom) { errorBanner }
    }

    // MARK: - Browser

    private var meetingsSplitView: some View {
        NavigationSplitView {
            sidebarList
            .listStyle(.sidebar)
            .navigationTitle("Meeting Assistant")
            .frame(minWidth: 248)
            // Large, always-visible primary action anchored to the sidebar.
            .safeAreaInset(edge: .bottom) {
                recordButton
                    .padding(Theme.Space.s)
                    .background(.bar)
            }
            .confirmationDialog(
                "Delete this meeting?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
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
            detail
                .frame(minWidth: 480)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { recordControl } }
        .onAppear { if selection == nil { selection = state.recordings.first?.meeting.id } }
        .onChange(of: state.recording?.id) { _, id in if let id { selection = id } }
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            // The in-progress recording appears instantly, before it's saved on
            // stop — so a meeting "exists" the moment Record is pressed.
            if let live = state.recording {
                liveRow(live).tag(live.id)
            }
            Section {
                ForEach(state.recordings, id: \.meeting.id) { rec in
                    meetingRow(rec)
                        .tag(rec.meeting.id)
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) { pendingDelete = rec }
                        }
                }
            } header: {
                if !state.recordings.isEmpty { Text("Recent") }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let live = state.recording, selection == live.id {
            RecordingDetailView(meeting: live)
        } else if let id = selection,
                  let rec = state.recordings.first(where: { $0.meeting.id == id }) {
            MeetingDetailView(recording: rec)
        } else if state.recordings.isEmpty {
            firstMeetingPrompt
        } else {
            emptyDetail
        }
    }

    // MARK: Sidebar rows

    private func meetingRow(_ rec: MeetingRecording) -> some View {
        let count = state.meetingSpeakers(for: rec).count
        return HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(rec.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.vertical, 3)
    }

    private func liveRow(_ meeting: Meeting) -> some View {
        HStack(spacing: Theme.Space.s) {
            PulsingDot()
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Recording").font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: Detail states

    private var firstMeetingPrompt: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Ready when you are").font(.title2).fontWeight(.semibold)
            Text("Calendar meetings record automatically when you join from Zoom, Teams, or Meet. Or start one now — your audio stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { Task { await state.startAdHocCapture() } } label: {
                Label("Record a meeting", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!state.modelReady)
            if !state.modelReady {
                Text("Preparing the transcription model…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

    private var emptyDetail: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "text.bubble").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("Select a meeting").font(.title3).fontWeight(.medium)
            Text("Pick a meeting from the sidebar to read its transcript.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Theme.Space.xl)
    }

    // MARK: Primary record action (large, in the sidebar)

    @ViewBuilder
    private var recordButton: some View {
        if state.isRecording {
            Button { Task { await state.stopCapture() } } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red).buttonStyle(.borderedProminent).controlSize(.large)
            .help("Stop recording and make the transcript")
        } else {
            Button { Task { await state.startAdHocCapture() } } label: {
                Label("Record a meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Start recording a meeting now")
        }
    }

    // The toolbar now shows only transcription progress; the record action is the
    // prominent sidebar button.
    @ViewBuilder
    private var recordControl: some View {
        if state.processing.current != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.progressPhase ?? "Transcribing…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder private var modelBanner: some View {
        if state.modelPreparing {
            HStack(spacing: Theme.Space.s) {
                if let f = state.modelDownloadFraction {
                    ProgressView(value: f).frame(width: 130)
                    Text("\(state.modelStatusText ?? "Preparing model…") \(Int(f * 100))%")
                } else {
                    ProgressView().controlSize(.small)
                    Text(state.modelStatusText ?? "Preparing model…")
                }
            }
            .font(.caption)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.top, Theme.Space.s)
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = state.lastError {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                Text(error).font(.callout).foregroundStyle(.white).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Button { state.dismissError() } label: {
                    Image(systemName: "xmark").foregroundStyle(.white.opacity(0.85))
                }.buttonStyle(.plain)
            }
            .padding(Theme.Space.m)
            .background(.red.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 3)
            .frame(maxWidth: 440).padding()
            .task(id: error) {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                state.dismissError()
            }
        }
    }
}

// MARK: - A gently pulsing dot for the live recording indicator.

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 8, height: 8)
            .opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Recording in progress

/// Status pane while a meeting is being recorded; the transcript appears here once
/// recording stops and processing finishes.
private struct RecordingDetailView: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) { PulsingDot(); SectionLabel("Recording in progress") }
            Text(meeting.title).font(.largeTitle).fontWeight(.semibold).multilineTextAlignment(.center)
            Text("Capturing audio. The transcript is made automatically when you stop — keep using your Mac; transcription runs afterward.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(role: .destructive) { Task { await state.stopCapture() } } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Theme.Space.xl)
    }
}

// MARK: - Transcript detail

/// Detail pane: the speaker-labeled transcript, in an elegant reading layout.
private struct MeetingDetailView: View {
    @EnvironmentObject private var state: AppState
    let recording: MeetingRecording
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.processing.current?.id == recording.meeting.id { progressRow }
            speakersSection
            ScrollView {
                MarkdownText(state.transcript(for: recording) ?? "_No transcript yet._")
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        let speakers = state.meetingSpeakers(for: recording)
        let provider = recording.meeting.provider?.displayName ?? "Meeting"
        let speakerText = speakers.count == 1 ? "1 speaker" : "\(speakers.count) speakers"
        let sub = (speakers.isEmpty ? provider : "\(provider) · \(speakerText)")
            + " · " + recording.recordedAt.formatted(date: .abbreviated, time: .shortened)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.meeting.title).font(.title2).fontWeight(.semibold)
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    private var actions: some View {
        let transcript = state.transcript(for: recording)
        return HStack(spacing: Theme.Space.s) {
            Button {
                copyToClipboard(transcript ?? ""); didCopy = true
            } label: { Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") }
                .disabled(transcript == nil)
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(nanoseconds: 1_500_000_000); didCopy = false
                }
            Menu {
                Button("Save to File…") { saveToFile(transcript ?? "", suggestedName: recording.meeting.title) }
                Button("Show in Finder") {
                    let url = state.transcriptURL(for: recording)
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
                Divider()
                Button("Make Transcript Again") { Task { await state.reprocess(recording) } }
                    .disabled(!state.modelReady)
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().disabled(transcript == nil)
        }
        .labelStyle(.titleAndIcon)
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = state.progressFraction {
                ProgressView(value: fraction) { Text(state.progressPhase ?? "Transcribing…").font(.caption) }
                Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.progressPhase ?? "Transcribing…").font(.caption)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var speakersSection: some View {
        let speakers = state.meetingSpeakers(for: recording)
        if !speakers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel("Speakers — rename to teach a voice")
                ForEach(speakers, id: \.self) { label in
                    SpeakerRenameRow(originalLabel: label) { newName in
                        state.renameSpeaker(in: recording, from: label, to: newName)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25))
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveToFile(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Renders the transcript markdown in a serif reading face, falling back to plain.
private struct MarkdownText: View {
    let content: String
    init(_ content: String) { self.content = content }
    var body: some View {
        Text((try? AttributedString(markdown: content,
              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
              ?? AttributedString(content))
            .font(Theme.reading)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.l)
    }
}

/// A Speakers-section row: current label + inline rename. Save enables only when
/// the draft is non-empty and changed.
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
        HStack(spacing: Theme.Space.s) {
            SpeakerChip(text: originalLabel, isMe: originalLabel == "Me").frame(width: 96, alignment: .leading)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                .onSubmit { if canSave { onRename(draft) } }
            Button { onRename(draft) } label: { Image(systemName: "checkmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(canSave ? Theme.accent : .secondary)
                .disabled(!canSave).help("Save new name")
        }
    }
}
