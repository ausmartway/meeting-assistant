cask "meeting-assistant" do
  version "0.4.22"
  sha256 "21afefb9ca5bd75f5e5d5d18c9e16f3de890c3e54c42a4ae5592e6624244e675"

  url "https://github.com/ausmartway/meeting-assistant/releases/download/v#{version}/MeetingAssistant.dmg",
      verified: "github.com/ausmartway/meeting-assistant/"
  name "Meeting Assistant"
  desc "Menu-bar app that auto-captures and locally transcribes meetings"
  homepage "https://github.com/ausmartway/meeting-assistant"

  # macOS 26 (Tahoe) is the floor — the app targets current-OS Macs only.
  # (Symbol form: Homebrew's OSDependsOn style rule rejects ">= :tahoe" while
  # Tahoe is the newest macOS; a bare symbol already means "this or newer".)
  depends_on macos: :tahoe

  app "Meeting Assistant.app"

  # Remove user data on `brew uninstall --zap`.
  zap trash: [
    "~/Library/Application Support/MeetingAssistant",
    "~/Library/Caches/com.meetingassistant.app",
    "~/Library/HTTPStorages/com.meetingassistant.app",
    "~/Library/Preferences/com.meetingassistant.app.plist",
  ]

  # The app is self-distributed and signed with a stable self-signed certificate
  # (so TCC permission grants persist across updates) but it is NOT Apple-notarized,
  # so Gatekeeper blocks the first launch. Heads-up plus the one-time workaround:
  caveats <<~EOS
    Meeting Assistant is not notarized by Apple, so macOS blocks its first launch.
    Allow it once (first launch only):

      System Settings → Privacy & Security → "Open Anyway".

    To skip that step, install without the Gatekeeper quarantine flag:

      brew install --cask --no-quarantine meeting-assistant

    On first launch the app opens its main window (with a Dock and menu-bar icon)
    and walks you through a short setup.
  EOS
end
