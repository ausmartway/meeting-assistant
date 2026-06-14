import SwiftUI
import MeetingKit

/// Main window: a sidebar list of past meetings and a detail pane showing the
/// speaker-labeled transcript and the AI summary.
struct MainWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?

    var body: some View {
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
            if let id = selection,
               let recording = state.recordings.first(where: { $0.meeting.id == id }) {
                MeetingDetailView(recording: recording)
            } else {
                ContentUnavailableViewCompat(
                    title: "No meeting selected",
                    systemImage: "doc.text.magnifyingglass",
                    description: "Pick a meeting to see its transcript and summary."
                )
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
                Text(error)
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).background(.red, in: Capsule()).padding()
            }
        }
    }
}

/// Detail pane with Summary / Transcript tabs.
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
                Button {
                    Task { await state.reprocess(recording) }
                } label: {
                    Label("Re-process", systemImage: "arrow.clockwise")
                }
                .disabled(!state.modelReady)
                .help(state.modelReady
                      ? "Re-run transcription and summary from the saved audio"
                      : "Waiting for the transcription model to finish downloading")
                Button {
                    Task { await state.resummarize(recording) }
                } label: {
                    Label("Re-summarize", systemImage: "sparkles")
                }
                .help("Re-run only the summary from the existing transcript")
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

            TabView {
                ScrollView { MarkdownText(state.transcript(for: recording) ?? "_No transcript yet._") }
                    .tabItem { Text("Transcript") }
                ScrollView { MarkdownText(state.summary(for: recording) ?? "_No summary yet._") }
                    .tabItem { Text("Summary") }
            }
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
