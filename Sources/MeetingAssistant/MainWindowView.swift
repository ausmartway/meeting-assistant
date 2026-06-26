import AppKit
import MeetingKit
import SwiftUI

/// Main window: a native translucent sidebar of meetings and a detail pane showing
/// the speaker-labeled transcript. Elegant, native-macOS styling (see `Theme`).
struct MainWindowView: View {
    @EnvironmentObject private var state: AppState
    /// Multi-selection of meeting ids (Cmd/Shift-click); drives the detail pane and
    /// bulk delete.
    @State private var selection = Set<String>()
    /// Meetings queued for the delete confirmation (one, or many for a bulk delete).
    @State private var pendingDelete: [MeetingRecording] = []
    @State private var searchText = ""

    var body: some View {
        Group {
            if !state.setup.isComplete {
                OnboardingView()
            } else {
                meetingsSplitView
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { errorBanner }
    }

    // MARK: - Browser

    private var meetingsSplitView: some View {
        NavigationSplitView {
            sidebarList
                .listStyle(.sidebar)
                .navigationTitle("Meeting Assistant")
                .frame(minWidth: 248)
                // Large, always-visible primary action anchored to the top of the sidebar.
                .safeAreaInset(edge: .top) {
                    recordButton
                        .padding(Theme.Space.s)
                        .background(.bar)
                }
                .safeAreaInset(edge: .bottom) {
                    SettingsLink {
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive").font(.system(size: 10))
                            Text(
                                "\(ByteCountFormatter.string(fromByteCount: state.storageBytes, countStyle: .file)) used"
                            )
                            .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Manage storage in Settings")
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                .confirmationDialog(
                    deleteTitle,
                    isPresented: Binding(
                        get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
                ) {
                    Button(deleteButtonLabel, role: .destructive) {
                        let targets = pendingDelete
                        for rec in targets { selection.remove(rec.meeting.id) }
                        state.deleteRecordings(targets)
                        pendingDelete = []
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = [] }
                } message: {
                    Text(deleteMessage)
                }
        } detail: {
            detail
                .frame(minWidth: 480)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { recordControl } }
        .onAppear {
            if selection.isEmpty, let first = state.recordings.first?.meeting.id {
                selection = [first]
            }
        }
        .onChange(of: state.recording?.id) { _, id in if let id { selection = [id] } }
    }

    /// The recordings currently selected (excludes the live, unsaved recording).
    private var selectedRecordings: [MeetingRecording] {
        state.recordings.filter { selection.contains($0.meeting.id) }
    }

    private var deleteTitle: String {
        pendingDelete.count <= 1
            ? "Delete this meeting?" : "Delete \(pendingDelete.count) meetings?"
    }
    private var deleteButtonLabel: String {
        pendingDelete.count <= 1 ? "Delete" : "Delete \(pendingDelete.count) Meetings"
    }
    private var deleteMessage: String {
        pendingDelete.count <= 1
            ? "This permanently deletes the recording and its transcript. This can't be undone."
            : "This permanently deletes \(pendingDelete.count) recordings and their transcripts. This can't be undone."
    }

    private var sidebarList: some View {
        let results = MeetingSearch.filter(
            state.recordings, query: searchText, haystackByID: state.searchIndex)
        return List(selection: $selection) {
            // The in-progress recording appears instantly, before it's saved on
            // stop — so a meeting "exists" the moment Record is pressed.
            if let live = state.recording {
                liveRow(live).tag(live.id)
            }
            Section {
                if results.isEmpty && !searchText.isEmpty {
                    Text("No meetings match \u{201C}\(searchText)\u{201D}")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(results, id: \.meeting.id) { rec in
                    meetingRow(rec)
                        .tag(rec.meeting.id)
                        .contextMenu { deleteMenu(for: rec) }
                }
            } header: {
                if !state.recordings.isEmpty {
                    Text(searchText.isEmpty ? "Recent" : "Results")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search meetings")
        // Delete key removes the current selection.
        .onDeleteCommand { if !selectedRecordings.isEmpty { pendingDelete = selectedRecordings } }
    }

    /// Right-click delete: acts on the whole selection when the clicked row is part
    /// of it (standard macOS behavior), otherwise just that one meeting.
    @ViewBuilder
    private func deleteMenu(for rec: MeetingRecording) -> some View {
        let targets =
            selection.contains(rec.meeting.id) && selection.count > 1 ? selectedRecordings : [rec]
        Button(
            targets.count == 1 ? "Delete Meeting" : "Delete \(targets.count) Meetings",
            role: .destructive
        ) { pendingDelete = targets }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count > 1 {
            multiSelectionDetail
        } else if let live = state.recording, selection.contains(live.id) {
            RecordingDetailView(meeting: live)
        } else if let id = selection.first,
            let rec = state.recordings.first(where: { $0.meeting.id == id })
        {
            MeetingDetailView(recording: rec, requestDelete: { pendingDelete = [rec] })
        } else if state.recordings.isEmpty {
            firstMeetingPrompt
        } else {
            emptyDetail
        }
    }

    /// Shown when several meetings are selected: a summary with a bulk delete.
    private var multiSelectionDetail: some View {
        let recordings = selectedRecordings
        return VStack(spacing: Theme.Space.m) {
            Image(systemName: "checklist")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("\(recordings.count) meetings selected")
                .font(.title2).fontWeight(.semibold)
            Text("Delete them together, or pick a single meeting to read its transcript.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: Theme.Space.s) {
                Button(role: .destructive) {
                    pendingDelete = recordings
                } label: {
                    Label("Delete \(recordings.count) Meetings", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                Button("Clear Selection") { selection = [] }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Theme.Space.xl)
    }

    // MARK: Sidebar rows

    private func meetingRow(_ rec: MeetingRecording) -> some View {
        let speakers = state.meetingSpeakers(for: rec)
        let count = speakers.count
        // Distinguish identical generic titles (e.g. "Microsoft Teams meeting") by
        // appending a named remote speaker — display only, the stored title is kept.
        let title = MeetingDisplayTitle.sidebarTitle(
            title: rec.meeting.title,
            providerDisplayName: rec.meeting.provider?.displayName,
            providerShortName: rec.meeting.provider?.shortName,
            speakers: speakers,
            localUserName: state.settings.localUserName)
        return HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(rec.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if count > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "person.2").font(.system(size: 10))
                    Text("\(count)").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .help("\(count) \(count == 1 ? "speaker" : "speakers")")
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
            Text(
                "Calendar meetings record automatically when you join from Zoom, Teams, or Meet. Or start one now — your audio stays on this Mac."
            )
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button {
                Task { await state.startAdHocCapture() }
            } label: {
                Label("Record a meeting", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!state.modelReady)
            if !state.modelReady {
                Text("Preparing the transcription model…").font(.caption).foregroundStyle(
                    .secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

    private var emptyDetail: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "text.bubble").font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
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
            Button {
                Task { await state.stopCapture() }
            } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red).buttonStyle(.borderedProminent).controlSize(.large)
            .help("Stop recording and make the transcript")
        } else {
            Button {
                Task { await state.startAdHocCapture() }
            } label: {
                Label("Record a meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Start recording a meeting now")
        }
    }

    // The toolbar shows transient status (transcription progress, or model
    // preparation) anchored top-trailing — never floating over the content. The
    // record action is the prominent sidebar button.
    @ViewBuilder
    private var recordControl: some View {
        if state.processing.current != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.progressPhase ?? "Transcribing…").font(.caption).foregroundStyle(
                    .secondary)
            }
        } else if state.modelPreparing {
            HStack(spacing: 6) {
                if let f = state.modelDownloadFraction {
                    ProgressView(value: f).frame(width: 90)
                    Text("\(state.modelStatusText ?? "Preparing model…") \(Int(f * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(state.modelStatusText ?? "Preparing model…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder private var errorBanner: some View {
        if let error = state.lastError {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                Text(error).font(.callout).foregroundStyle(.white).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Button {
                    state.dismissError()
                } label: {
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
            HStack(spacing: Theme.Space.s) {
                PulsingDot()
                SectionLabel("Recording in progress")
            }
            Text(meeting.title).font(.largeTitle).fontWeight(.semibold).multilineTextAlignment(
                .center)
            Text(
                "Capturing audio. The transcript is made automatically when you stop — keep using your Mac; transcription runs afterward."
            )
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(role: .destructive) {
                Task { await state.stopCapture() }
            } label: {
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
    /// Ask the window to start its delete-confirmation flow for this recording.
    let requestDelete: () -> Void
    @State private var didCopy = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.processing.current?.id == recording.meeting.id { progressRow }
            // Reading column on the left; a fixed details inspector (Speakers) on the
            // right, so a wide window's space is used instead of left as empty gutters.
            HStack(alignment: .top, spacing: 0) {
                TranscriptReadingView(
                    document: state.transcript(for: recording),
                    localUserName: state.settings.localUserName
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if !state.meetingSpeakers(for: recording).isEmpty {
                    Divider()
                    detailsInspector
                        .frame(width: 280)
                }
            }
        }
    }

    private var header: some View {
        let speakers = state.meetingSpeakers(for: recording)
        let provider = recording.meeting.provider?.displayName ?? "Meeting"
        let speakerText = speakers.count == 1 ? "1 speaker" : "\(speakers.count) speakers"
        let sub =
            (speakers.isEmpty ? provider : "\(provider) · \(speakerText)")
            + " · " + recording.recordedAt.formatted(date: .abbreviated, time: .shortened)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                editableTitle
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
                if !state.hasAudio(for: recording) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text(
                            "Audio cleared to save space — transcript kept. Re-transcribing isn't available."
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                    .background(
                        .quaternary.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .padding(.top, 2)
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    /// The meeting title, editable in place: click it to rename (no menus). Commits
    /// on Enter or when focus leaves; Esc cancels.
    @ViewBuilder private var editableTitle: some View {
        if editingTitle {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.title2).fontWeight(.semibold)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { editingTitle = false }  // Esc cancels
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        } else {
            Text(recording.meeting.title)
                .font(.title2).fontWeight(.semibold)
                .contentShape(Rectangle())
                .onTapGesture { startEditingTitle() }
                .help("Click to rename")
        }
    }

    private func startEditingTitle() {
        titleDraft = recording.meeting.title
        editingTitle = true
        titleFocused = true
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        state.renameRecording(recording, to: titleDraft)
    }

    private var actions: some View {
        let transcript = state.transcript(for: recording)
        return HStack(spacing: Theme.Space.s) {
            Button {
                copyToClipboard(transcript ?? "")
                didCopy = true
            } label: {
                Label(
                    didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(transcript == nil)
            .task(id: didCopy) {
                guard didCopy else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                didCopy = false
            }

            Button {
                saveToFile(transcript ?? "", suggestedName: recording.meeting.title)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(transcript == nil)

            Button {
                let url = state.transcriptURL(for: recording)
                NSWorkspace.shared.selectFile(
                    url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(transcript == nil)

            Button {
                Task { await state.reprocess(recording) }
            } label: {
                Label("Make Again", systemImage: "arrow.clockwise")
            }
            .disabled(!state.modelReady || !state.hasAudio(for: recording))
            .help(
                state.hasAudio(for: recording)
                    ? "Make the transcript again"
                    : "Audio was cleared to save space — re-transcribing isn't available.")

            // Separate the destructive action from the safe ones.
            Divider().frame(height: 16)

            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
    }

    private var progressRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = state.progressFraction {
                    ProgressView(value: fraction) {
                        Text(state.progressPhase ?? "Transcribing…").font(.caption)
                    }
                    Text("\(Int(fraction * 100))%" + (state.progressETA.map { " · \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.progressPhase ?? "Transcribing…").font(.caption)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                state.stopCurrentTranscription()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trailing details panel: the Speakers editor (and room for future meeting
    /// details). Fills the right side of wide windows so the reading column can stay
    /// a comfortable measure without leaving the rest of the pane empty.
    private var detailsInspector: some View {
        let speakers = state.meetingSpeakers(for: recording)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel("Speakers")
                Text("Renaming a speaker teaches their voice for future meetings.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(speakers, id: \.self) { label in
                    SpeakerRenameRow(
                        originalLabel: label,
                        localUserName: state.settings.localUserName
                    ) { newName in
                        state.renameSpeaker(in: recording, from: label, to: newName)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.m)
        }
        .background(.quaternary.opacity(0.18))
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

/// The transcript as a real document: structured per-speaker turns in a centered,
/// measure-constrained serif column (not a raw-Markdown dump). Parses the stored
/// document via `TranscriptParser`; Copy/Export still use the raw string.
private struct TranscriptReadingView: View {
    let document: String?
    let localUserName: String

    var body: some View {
        let parsed = TranscriptParser.parse(document ?? "")
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if parsed.turns.isEmpty {
                    Text(document == nil ? "No transcript yet." : "This transcript is empty.")
                        .font(Theme.reading).foregroundStyle(.secondary)
                        .padding(.vertical, Theme.Space.l)
                } else {
                    if let note = parsed.note {
                        Text(note)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.bottom, Theme.Space.m)
                    }
                    ForEach(Array(parsed.turns.enumerated()), id: \.offset) { _, turn in
                        TurnView(turn: turn, localUserName: localUserName)
                            .padding(.bottom, Theme.Space.m)
                    }
                    transcriptFooter(parsed)
                }
            }
            // Fill the available width between the sidebar and the details inspector
            // (no measure cap), left-aligned.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.l)
        }
    }

    private func transcriptFooter(_ parsed: TranscriptParser.Parsed) -> some View {
        var words = 0
        for turn in parsed.turns {
            words += Self.wordCount(turn.text)
        }
        let speakers = Set(parsed.turns.map(\.speaker)).count
        return Text(
            "\(words) \(words == 1 ? "word" : "words") · \(speakers) \(speakers == 1 ? "speaker" : "speakers")"
        )
        .font(.caption).foregroundStyle(.secondary)
        .padding(.top, Theme.Space.s)
    }

    /// Count words: space-delimited tokens for Latin-style text, plus each CJK
    /// ideograph as its own word (Chinese/Japanese have no spaces between words).
    private static func wordCount(_ text: String) -> Int {
        var cjk = 0
        for scalar in text.unicodeScalars where isCJK(scalar) { cjk += 1 }
        let spaced = text.unicodeScalars.filter { !isCJK($0) }
        let nonCJK = String(String.UnicodeScalarView(spaced))
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        return cjk + nonCJK
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
    }
}

/// One speaker turn: a colored name + quiet timestamp header, serif speech beneath.
private struct TurnView: View {
    let turn: TranscriptParser.Turn
    let localUserName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(turn.speaker)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        Theme.speakerColor(for: turn.speaker, localUserName: localUserName))
                if !turn.time.isEmpty {
                    Text(turn.time)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(turn.text)
                .font(Theme.reading)
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Speakers-section row: a single editable name field (the source of truth — no
/// redundant chip). Return or the Save button (shown only when the draft is
/// non-empty and changed) commits the rename. The local user's row is marked "you".
private struct SpeakerRenameRow: View {
    let originalLabel: String
    let localUserName: String
    let onRename: (String) -> Void
    @State private var draft: String

    init(originalLabel: String, localUserName: String, onRename: @escaping (String) -> Void) {
        self.originalLabel = originalLabel
        self.localUserName = localUserName
        self.onRename = onRename
        _draft = State(initialValue: originalLabel)
    }
    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && draft != originalLabel
    }
    private var isMe: Bool { originalLabel == localUserName || originalLabel == "Me" }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                .onSubmit { if canSave { onRename(draft) } }
            if isMe {
                Text("you").font(.caption).foregroundStyle(.secondary)
            }
            if canSave {
                Button {
                    onRename(draft)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .help("Save new name")
            }
            Spacer(minLength: 0)
        }
    }
}
