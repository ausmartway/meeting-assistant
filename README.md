# Meeting Assistant

A native macOS app that automatically captures your meetings (Zoom, Google Meet,
Microsoft Teams) and turns them into clean, **speaker-labeled transcripts** —
transcribed **entirely on your Mac**. Your audio and transcripts never leave the
device; nothing is uploaded to any server.

## Highlights

- **Automatic capture.** When a calendar meeting starts and you join from the
  Zoom, Teams, or Meet app, recording begins on its own. You can also record any
  meeting on demand.
- **Private & on-device.** Transcription runs locally on Apple Silicon. No cloud,
  no account, no data leaving your Mac.
- **Knows who said what.** Your voice is always labeled "Me." When you share a
  room with several people, it tells the in-room voices apart, and you can **name
  a speaker once** — it remembers that voice and labels them automatically in
  future meetings.
- **English + Mandarin**, auto-detected. No language setting to fiddle with.
- **Keep working.** Recording is light; transcription happens after the meeting,
  and you can start a new recording while an earlier one is still transcribing.

Requires macOS 14 (Sonoma) or later on Apple Silicon. Comfortable on 16 GB.

## Install

### Homebrew (recommended)

```sh
brew tap ausmartway/meeting-assistant https://github.com/ausmartway/meeting-assistant
brew install --cask meeting-assistant
```

The app isn't notarized by Apple, so macOS blocks the first launch — `brew` prints
the one-time "Open Anyway" steps. To skip them, add `--no-quarantine`:
`brew install --cask --no-quarantine meeting-assistant`. Update later with
`brew upgrade --cask meeting-assistant`.

### Manual (DMG)

1. Download `MeetingAssistant.dmg` from the [latest release][releases] and open it.
2. Drag **Meeting Assistant** onto the **Applications** folder.
3. Open it from Applications. Because the app is self-distributed (not signed by a
   paid Apple Developer account), macOS blocks the first launch. To allow it
   (first time only):
   - **macOS 15 (Sequoia) and later** (incl. macOS 26): open **System Settings →
     Privacy & Security**, scroll to **Security**, click **Open Anyway**,
     authenticate, then **Open Anyway** again.
   - **macOS 14 (Sonoma):** **right-click the app → Open**, then **Open**.

> **Tip:** after you enable **Screen & System Audio Recording**, you may need to
> quit and reopen the app for it to take effect.

[releases]: https://github.com/ausmartway/meeting-assistant/releases

## Using it

On first launch, **Meeting Assistant** opens its main window (and adds a Dock icon
plus a menu-bar icon for quick status and control). A short setup walks you through
granting the permissions it needs — Screen & System Audio Recording, Microphone,
Calendar, Accessibility, and Notifications — and, optionally, lets you **teach it
your voice** by reading a sentence aloud so you're always labeled "Me."

After that:

- **It records automatically** when a calendar meeting starts and you join from
  Zoom, Teams, or Meet. A meeting appears in the sidebar the moment recording
  begins.
- **Record any time** with the **Record a meeting** button (top of the window) or
  from the menu-bar icon — handy for ad-hoc calls that aren't on your calendar.
- **Read the transcript** in the main window once a meeting ends and processing
  finishes. Copy or export it from there.
- **Name speakers.** In a transcript, rename an anonymous speaker (e.g.
  "Speaker 2" → a name); the app learns that voice and recognizes the person in
  later meetings.

Everything stays on your Mac.

## Status

Current release: **v0.4.0**. The app is in active use and stable for everyday
meetings. On-screen name detection for remote participants is best-effort and
varies by app, theme, and layout — the microphone-vs-others split and your
enrolled voice are the reliable signals. Live (real-time) transcription is
intentionally not included; the transcript is produced after the meeting for
higher accuracy.

---

## For developers

The rest of this document is about building and how the app works internally; end
users can stop here.

### Design principle: cheap live capture, heavy post-processing

To stay responsive **during** a call, the app does almost nothing expensive while
recording. It only writes the **microphone** (you) and **system audio** (everyone
else) to two separate files, and samples one video frame every few seconds to note
who's highlighted on screen. The heavy work — transcription, speaker diarization,
and labeling — runs **after** the meeting on the idle GPU.

### Pipeline

```
EventKit ─▶ CalendarWatcher ─▶ MeetingDetector
   └▶ auto-start when a calendared meeting starts AND its app is running
CaptureSession  [LIVE: ScreenCaptureKit system audio + AVAudioEngine mic + frame sampling]
   ─▶ MeetingRecording bundle on disk
   ─▶ (meeting ends / you click Stop) ─▶ MeetingProcessor
        Transcriber ─▶ HallucinationFilter ─▶ Diarizer ─▶ SpeakerRecognizer
          ─▶ SpeakerFuser ─▶ TranscriptFormatter ─▶ MeetingStore
   ─▶ transcript.md  ─▶ main window
```

**Speaker labeling** combines several signals: the mic-vs-system split gives an
exact "you vs. others" attribution that never fails; on the mic channel,
**FluidAudio** diarization separates multiple in-room voices, which
`SpeakerRecognizer` matches against a **local voice library** (`SpeakerLibrary`)
to attach known names — your enrolled voice becomes "Me," others stay
"Speaker N" until you name them. For remote participants, the on-screen
active-speaker highlight + OCR'd name is used best-effort.

### Build

```sh
swift test                   # run the unit tests (needs full Xcode toolchain active)
./Scripts/setup-signing.sh   # ONE TIME: create a stable signing identity (see below)
./Scripts/install.sh --run   # build, install to /Applications (single copy), launch
./Scripts/make-dmg.sh        # package a drag-to-install DMG
```

| Path | What |
|---|---|
| `Sources/MeetingKit/` | Core library: models + pure logic + Apple-framework integrations |
| `Sources/MeetingAssistant/` | SwiftUI app: windows, menu bar, settings, orchestration |
| `Tests/MeetingKitTests/` | Unit tests (swift-testing) for the pure logic |
| `Resources/` | `Info.plist`, entitlements |
| `Scripts/` | `build-app.sh`, `install.sh`, `make-dmg.sh`, `setup-signing.sh`, `make-icns.sh` |
| `Casks/` | Homebrew cask (`meeting-assistant.rb`) |

See [`REQUIREMENTS.md`](REQUIREMENTS.md) for the product requirements and
[`CLAUDE.md`](CLAUDE.md) for architecture notes.

### Why `setup-signing.sh` matters (persistent permissions)

macOS ties permission grants (Screen & Audio Recording, Accessibility) to the
app's **code-signing identity**. A plain build is *ad-hoc* signed — no stable
identity — so every rebuild looks like a new app and those grants silently reset.
`setup-signing.sh` creates a **self-signed certificate** in a dedicated keychain
(the private key never leaves your Mac); `build-app.sh` signs every build with that
one identity, so you grant permissions once and they persist across builds. The
released DMGs (built by GitHub Actions) use the **same** certificate, so
locally-built and downloaded builds share an identity and grants carry across both.
It's self-signed, not Apple-notarized, so first launch still needs the Gatekeeper
step above.

### On-device transcription

- **WhisperKit** for speech-to-text (`WhisperKitTranscriber`), using **multilingual**
  models with **language auto-detection** (English + Mandarin, incl. reasonable
  code-switching). The hallucination filter and on-screen name OCR are Chinese-aware.
- Runs the encoder/decoder on the **GPU** (`ModelComputeOptions`) to avoid the slow
  first-time Apple Neural Engine compile.
- The model downloads at launch into `Application Support/MeetingAssistant/WhisperModels/`.
- `Backends.swift` selects the real engine via `#if canImport(WhisperKit)` and falls
  back to a stub otherwise.
- Long meetings (2 h+) transcribe within a flat memory budget via WhisperKit **VAD
  chunking** with a bounded worker count; both channels share one model load.

Requires **full Xcode** to build (Metal/CoreML toolchain).
