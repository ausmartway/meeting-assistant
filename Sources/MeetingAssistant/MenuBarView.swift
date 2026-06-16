import SwiftUI
import MeetingKit

/// The menu-bar dropdown: current status, the next meeting, and Start/Stop.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                Text("Meeting Assistant").font(.headline)
            }

            Divider()

            // Setup is the first thing to fix — until it's done, recording can't work.
            if !state.setup.isComplete {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label("Finish setup to start recording", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            Label {
                Text(state.statusSummary)
            } icon: {
                Image(systemName: statusSymbol)
                    .foregroundStyle(isRecording ? .red : .primary)
            }
            .font(.subheadline)

            // Model readiness (downloaded at launch; processing waits for it).
            if state.modelPreparing {
                VStack(alignment: .leading, spacing: 4) {
                    if let f = state.modelDownloadFraction {
                        ProgressView(value: f) {
                            Text(state.modelStatusText ?? "Preparing model…").font(.caption)
                        }
                        Text("\(Int(f * 100))%").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(state.modelStatusText ?? "Preparing model…").font(.caption)
                        }
                    }
                }
            } else if state.modelReady {
                Label("Ready to transcribe", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.modelFailed {
                // Preparation failed — offer a one-tap retry here, rather than
                // sending the user hunting through Settings.
                Button {
                    Task { await state.prepareModel() }
                } label: {
                    Label(state.modelStatusText ?? "Download failed — tap to retry",
                          systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }

            if let next = state.upcoming.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next meeting").font(.caption).foregroundStyle(.secondary)
                    Text(next.title).font(.callout)
                    Text("\(next.provider?.displayName ?? "Meeting") · \(next.startDate.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            controls

            Divider()

            HStack {
                Button("Show Transcripts") { openWindow(id: "main") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Recording control — independent of transcription, so you can stop one
            // meeting and immediately start another while the first transcribes.
            if state.isRecording {
                Button(role: .destructive) {
                    Task { await state.stopCapture() }
                } label: {
                    Label("Stop & Transcribe", systemImage: "stop.circle")
                }
            } else {
                // Start the next calendared meeting, when there is one.
                if let next = state.upcoming.first {
                    Button {
                        Task { await state.startCapture(for: next) }
                    } label: {
                        Label("Record “\(next.title)”", systemImage: "record.circle")
                    }
                }
                // Always available: record a meeting with no calendar entry.
                Button {
                    Task { await state.startAdHocCapture() }
                } label: {
                    Label("Record a Meeting Now", systemImage: "record.circle.fill")
                }
            }

            // Transcription progress — shown whenever a transcript is being made,
            // even while a new meeting is recording.
            if state.processing.current != nil {
                Divider()
                if let fraction = state.progressFraction {
                    ProgressView(value: fraction) {
                        Text(state.progressPhase ?? "Making transcript…").font(.caption)
                    }
                    Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(state.progressPhase ?? "Making transcript…").font(.caption)
                    }
                }
                if state.processing.pendingCount > 0 {
                    Text("\(state.processing.pendingCount) more queued")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isRecording: Bool { state.isRecording }

    private var statusSymbol: String {
        if state.isRecording { return "record.circle.fill" }
        if state.processing.current != nil { return "gearshape.2" }
        return "waveform"
    }
}
