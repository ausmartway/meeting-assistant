cask "meeting-assistant" do
  version "0.4.3"
  sha256 "9e1ac7c48c46765a2f6c40679ceee03e92d9f1933405477f11c7ec71d4a67d39"

  url "https://github.com/ausmartway/meeting-assistant/releases/download/v#{version}/MeetingAssistant.dmg",
      verified: "github.com/ausmartway/meeting-assistant/"
  name "Meeting Assistant"
  desc "Menu-bar app that auto-captures and locally transcribes meetings"
  homepage "https://github.com/ausmartway/meeting-assistant"

  # macOS 14 (Sonoma) is the floor: EventKit full-access, ScreenCaptureKit audio,
  # and the Vision OCR APIs the app relies on.
  depends_on macos: :sonoma

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

      • macOS 15 / 26: System Settings → Privacy & Security → "Open Anyway".
      • macOS 14:      right-click the app in Applications → Open → Open.

    To skip that step, install without the Gatekeeper quarantine flag:

      brew install --cask --no-quarantine meeting-assistant

    On first launch the app opens its main window (with a Dock and menu-bar icon)
    and walks you through a short setup.
  EOS
end
