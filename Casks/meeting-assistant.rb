cask "meeting-assistant" do
  version "0.4.0"
  sha256 "d23f3a319ec400bd9895d9d0774c9bbb9527b7bc0f52a93af9c07331a6b01a0e"

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

    The app lives in your menu bar and opens a setup window on first launch.
  EOS
end
