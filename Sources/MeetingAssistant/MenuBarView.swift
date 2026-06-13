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

            Label(state.status.label, systemImage: statusSymbol)
                .font(.subheadline)

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
                Button("Open Window") { openWindow(id: "main") }
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
        switch state.status {
        case .recording:
            Button(role: .destructive) {
                Task { await state.stopCapture() }
            } label: {
                Label("Stop & Process", systemImage: "stop.circle")
            }
        case .processing:
            HStack { ProgressView().controlSize(.small); Text("Processing…") }
        case .idle:
            if let next = state.upcoming.first {
                Button {
                    Task { await state.startCapture(for: next) }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
            } else {
                Text("No upcoming meetings").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusSymbol: String {
        switch state.status {
        case .idle: return "moon.zzz"
        case .recording: return "record.circle"
        case .processing: return "gearshape.2"
        }
    }
}
