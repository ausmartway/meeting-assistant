import SwiftUI
import MeetingKit

/// First-run guidance. Shown in the main window until the required permissions
/// are granted, so a new user is walked from install → ready without ever having
/// to hunt through the Settings window. Optional capabilities are listed too, but
/// don't block completion.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

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

                VStack(alignment: .leading, spacing: 6) {
                    Label("Auto-recording works when you join from the Zoom, Teams, or Google Meet app.",
                          systemImage: "info.circle")
                    Label("Everything runs on your Mac. Your audio and transcripts never leave this computer.",
                          systemImage: "lock.fill")
                }
                .font(.caption).foregroundStyle(.secondary)
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
