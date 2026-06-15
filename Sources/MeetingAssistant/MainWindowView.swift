import SwiftUI
import MeetingKit

/// Main window: a sidebar list of past meetings and a detail pane showing the
/// speaker-labeled transcript.
struct MainWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?

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
            }
            .navigationTitle("Meetings")
            .frame(minWidth: 220)
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
    }

    /// Shown when there are no recordings yet — a real empty state with a clear
    /// call to action rather than a "pick a meeting" prompt with nothing to pick.
    private var firstMeetingPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No meetings yet").font(.headline)
            Text("Your transcripts will appear here. The app records calendar meetings automatically — or start one now.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(recording.meeting.title).font(.title2).bold()
                    Text(recording.meeting.provider?.displayName ?? "Meeting")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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

            ScrollView { MarkdownText(state.transcript(for: recording) ?? "_No transcript yet._") }
        }
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
