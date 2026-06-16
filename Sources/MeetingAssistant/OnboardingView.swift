import SwiftUI
import MeetingKit

/// First-run guidance. Shown in the main window until the required permissions
/// are granted, so a new user is walked from install → ready without ever having
/// to hunt through the Settings window. Optional capabilities are listed too, but
/// don't block completion.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var enroller = EnrollmentRecorder()
    @State private var enrollmentFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 0) {
                    ForEach(SetupCapability.allCases, id: \.self) { capability in
                        capabilityRow(capability)
                        if capability != SetupCapability.allCases.last { Divider() }
                    }
                }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                voiceEnrollment

                VStack(alignment: .leading, spacing: 6) {
                    Label("Auto-recording works when you join from the Zoom, Teams, or Google Meet app.",
                          systemImage: "info.circle")
                    Label("Everything runs on your Mac. Your audio and transcripts never leave this computer.",
                          systemImage: "lock.fill")
                }
                .font(.caption).foregroundStyle(.secondary)

                Divider()

                // Screen & Audio Recording (and sometimes Window Detection) only
                // take effect after a relaunch — give the user a one-click way to do
                // it instead of telling them to quit and reopen manually.
                HStack(spacing: 12) {
                    Text("Turned on a permission that's still not taking effect? Some need a restart.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart App") { state.relaunch() }
                        .buttonStyle(.bordered)
                        .fixedSize()
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 40)).foregroundStyle(.tint)
            Text("Welcome to Meeting Assistant").font(.title).bold()
            Text(state.setup.headline)
                .font(.title3).foregroundStyle(.secondary)
        }
    }

    // Voice enrollment is entirely optional — it powers in-room speaker labeling
    // but the app transcribes fine without it, so it's presented as its own card
    // (not a checklist row that could read as "blocking").
    private var voiceEnrollment: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.settings.isEnrolled ? "checkmark.circle.fill" : "person.wave.2")
                    .font(.title3)
                    .foregroundStyle(state.settings.isEnrolled ? .green : .secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Teach the app your voice").font(.headline)
                        Text("Optional")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text("Teach the app your voice so it can label you as \u{201C}Me\u{201D} when several people share a room.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if state.settings.isEnrolled {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Your voice is enrolled").font(.callout)
                    Spacer()
                    Button("Re-record") { startEnrollment() }
                        .buttonStyle(.bordered)
                        .disabled(enroller.isRecording)
                }
            } else {
                // Show the passage to read aloud in a readable, bordered block.
                Text(EnrollmentScript.passage)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                HStack(spacing: 12) {
                    if enroller.isRecording {
                        ProgressView().controlSize(.small)
                        Text("Recording\u{2026} read the paragraph above.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { enroller.stop() }
                            .buttonStyle(.borderedProminent)
                    } else if state.isEnrolling {
                        ProgressView().controlSize(.small)
                        Text(state.modelStatusText ?? "Processing your voice\u{2026}")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        Text("Find a quiet spot, then read the paragraph aloud.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Record") { startEnrollment() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if enrollmentFailed {
                    Text("That recording didn't work. Please try again in a quiet spot.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func startEnrollment() {
        enrollmentFailed = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-\(UUID().uuidString).wav")
        enroller.record(to: url) { result in
            switch result {
            case .success(let fileURL):
                Task {
                    let ok = await state.enrollMe(audioFile: fileURL)
                    if !ok { enrollmentFailed = true }
                    try? FileManager.default.removeItem(at: fileURL)
                }
            case .failure:
                enrollmentFailed = true
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(_ capability: SetupCapability) -> some View {
        let status = state.setup.status(capability)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(status == .granted ? .green : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(capability.title).font(.headline)
                    if !capability.isRequired {
                        Text("Optional")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(capability.purpose)
                    .font(.callout).foregroundStyle(.secondary)
                // Screen Recording / Accessibility have no in-app grant — always show
                // the tailored "do it in System Settings" hint so the user isn't
                // stranded clicking a button that can't toggle them on.
                if status != .granted, let hint = capability.grantHint {
                    Text(hint)
                        .font(.caption).foregroundStyle(.orange)
                } else if status == .denied {
                    Text("Turn this on in System Settings → Privacy & Security, then return here.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer()

            if status == .granted {
                Text("On").font(.callout).foregroundStyle(.green)
            } else {
                // "Turn On" implies an in-app toggle; for System-Settings-only
                // capabilities, say what the button actually does.
                Button(capability.requiresSystemSettings ? "Open System Settings" : "Turn On") {
                    Task { await state.grant(capability) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }
}
