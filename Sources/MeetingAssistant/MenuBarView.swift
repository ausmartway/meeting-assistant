import MeetingKit
import SwiftUI

/// The menu-bar dropdown: current status, the next meeting, and Start/Stop.
/// Follows the HIG shape for a menu-bar-extra window: identity header, status,
/// one prominent primary action, then quiet secondary actions.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header

            Divider()

            // Setup is the first thing to fix — until it's done, recording can't work.
            if !state.setup.isComplete {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label(
                        "Finish setup to start recording",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            status

            if let next = state.upcoming.first, !state.isRecording {
                nextMeeting(next)
            }

            primaryAction

            secondaryRecordAction

            if state.isRecording, let warning = state.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            transcriptionProgress

            Divider()

            // Voice enrollment lives in Settings → Speakers; surface it here so
            // it's reachable without hunting (the menu bar has no app menu).
            SettingsLink {
                Label(
                    state.settings.isEnrolled ? "Settings (voice enrolled)" : "Set Up My Voice…",
                    systemImage: "person.wave.2")
            }
            .font(.callout)

            HStack {
                Button("Show Transcripts") { openWindow(id: "main") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(Theme.Space.m)
        .frame(width: 300)
        .tint(Theme.accent)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "waveform.circle.fill")
                .font(.title3).foregroundStyle(Theme.accent)
            Text("Meeting Assistant").font(.headline)
        }
    }

    @ViewBuilder
    private var status: some View {
        Label {
            Text(state.statusSummary)
        } icon: {
            Image(systemName: statusSymbol)
                .foregroundStyle(state.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
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
                    HStack(spacing: Theme.Space.xs) {
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
                Label(
                    state.modelStatusText ?? "Download failed — tap to retry",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
            }
        }
    }

    private func nextMeeting(_ next: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Next meeting").font(.caption).foregroundStyle(.secondary)
            Text(next.title).font(.callout)
            Text(
                "\(next.provider?.displayName ?? "Meeting") · \(next.startDate.formatted(date: .omitted, time: .shortened))"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The one prominent action: Stop while recording, otherwise Record. Recording
    /// is independent of transcription, so you can stop one meeting and immediately
    /// start another while the first transcribes.
    @ViewBuilder
    private var primaryAction: some View {
        if state.isRecording {
            Button {
                Task { await state.stopCapture() }
            } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button {
                Task { await state.startAdHocCapture() }
            } label: {
                Label("Record a Meeting Now", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Start the next calendared meeting, when there is one.
    @ViewBuilder
    private var secondaryRecordAction: some View {
        if !state.isRecording, let next = state.upcoming.first {
            Button {
                Task { await state.startCapture(for: next) }
            } label: {
                Label("Record “\(next.title)”", systemImage: "record.circle")
            }
            .font(.callout)
        }
    }

    /// Transcription progress — shown whenever a transcript is being made,
    /// even while a new meeting is recording.
    @ViewBuilder
    private var transcriptionProgress: some View {
        if state.processing.current != nil {
            Divider()
            if let fraction = state.progressFraction {
                ProgressView(value: fraction) {
                    Text(state.progressPhase ?? "Making transcript…").font(.caption)
                }
                Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(state.progressPhase ?? "Making transcript…").font(.caption)
                }
            }
            if state.processing.pendingCount > 0 {
                Text("\(state.processing.pendingCount) more queued")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                state.stopCurrentTranscription()
            } label: {
                Label("Stop Transcript", systemImage: "stop.circle")
            }
            .controlSize(.small)
        }
    }

    private var statusSymbol: String {
        if state.isRecording { return "record.circle.fill" }
        if state.processing.current != nil { return "gearshape.2" }
        return "waveform"
    }
}
