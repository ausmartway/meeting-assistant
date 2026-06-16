# Meeting Assistant

A native macOS menu-bar app that watches your calendar, automatically captures
meetings (Zoom, Google Meet, Microsoft Teams) when they start, and produces a
**speaker-labeled transcript** — transcribed locally on Apple Silicon.

Target hardware: MacBook Pro M1 Pro, macOS 14 (Sonoma)+. Runs comfortably on
16 GB.

## Install

### Homebrew (recommended)

```sh
brew tap ausmartway/meeting-assistant https://github.com/ausmartway/meeting-assistant
brew install --cask meeting-assistant
```

The app isn't notarized by Apple, so macOS blocks the first launch — `brew`
prints the one-time "Open Anyway" steps (or install with `--no-quarantine` to
skip them). Update later with `brew upgrade --cask meeting-assistant`.

### Manual (DMG)

1. Download `MeetingAssistant.dmg` and double-click it.
2. Drag **Meeting Assistant** onto the **Applications** folder in the window.
3. Open **Applications** and double-click **Meeting Assistant**. Because the app
   is self-distributed and not signed by a paid Apple Developer account, macOS
   blocks it the first time. To allow it (first launch only):
   - On **macOS 15 (Sequoia) and later** (incl. macOS 26): after the "blocked"
     message, open **System Settings → Privacy & Security**, scroll to the
     **Security** section, click **Open Anyway**, authenticate, then click
     **Open Anyway** again. (Apple removed the old right-click → Open button.)
   - On **macOS 14 (Sonoma)**: **right-click Meeting Assistant → Open**, then
     click **Open** in the dialog.
4. The app lives in your **menu bar** (top-right of the screen), not the Dock. On
   first launch it opens a setup window that walks you through turning on the
   permissions it needs. Follow the checklist until everything shows a green
   check, then you're ready.

> **Tip:** After you turn on **Screen & Audio Recording** in System Settings, you
> may need to quit and reopen Meeting Assistant for it to take effect.

That's it — when a calendar meeting starts and you join from the Zoom, Teams, or
Google Meet app, recording begins automatically. You can also click **Record a
Meeting Now** from the menu-bar icon anytime.

## Design principle: cheap live capture, heavy post-processing

To stay responsive **during** a call, the app does almost nothing expensive while
recording. It only:

- writes the **microphone** (you) and **system audio** (everyone else) to two
  separate files, and
- samples one video frame every few seconds to note who's highlighted on screen.

The heavy work — transcription and speaker labeling — runs **after** the meeting
ends, on the idle GPU. Your Mac stays free while you're in the meeting.

## How it works

```
EventKit ─▶ CalendarWatcher ─▶ (start time) ─▶ MeetingDetector
   └▶ auto-start when a calendared meeting starts AND its app is running
CaptureSession  [LIVE: ScreenCaptureKit system audio + AVAudioEngine mic + frame sampling]
   ─▶ MeetingRecording bundle on disk
   ─▶ (you click Stop) ─▶ MeetingProcessor
        Transcriber ─▶ HallucinationFilter ─▶ SpeakerFuser ─▶ MeetingStore
   ─▶ transcript.md  ─▶ main window
```

You can also record an **ad-hoc meeting** that isn't on your calendar from the
menu bar.

**Speaker labeling** combines two signals: the mic-vs-system split gives an exact
"you vs. others" attribution that never fails, and the on-screen active-speaker
highlight + OCR'd name (best-effort) attaches real names to remote speakers,
degrading to "Speaker" when a name can't be read.

## Project layout

| Path | What |
|---|---|
| `Sources/MeetingKit/` | Core library: models + pure logic + Apple-framework integrations |
| `Sources/MeetingAssistant/` | SwiftUI menu-bar app, settings, orchestration |
| `Tests/MeetingKitTests/` | Unit tests (swift-testing) for the pure logic |
| `Resources/` | `Info.plist`, entitlements |
| `Scripts/` | `test.sh`, `build-app.sh`, `install.sh`, `make-dmg.sh` |

Key components (all in `Sources/MeetingKit`):
`MeetingURLParser`, `CalendarWatcher`, `MeetingDetector`, `CaptureSession`,
`SpeakerSampler`, `Transcriber`, `SpeakerFuser`, `HallucinationFilter`,
`WhisperTextCleaner`, `TranscriptFormatter`, `MeetingProcessor`, `MeetingStore`.

## Build from source (developers)

End users should follow [Install](#install) above. To build it yourself:

```sh
swift test                   # run the unit tests (needs full Xcode toolchain active)
./Scripts/setup-signing.sh   # ONE TIME: create a stable signing identity (see below)
./Scripts/install.sh --run   # build, install to /Applications (single copy), launch
./Scripts/make-dmg.sh        # package a drag-to-install DMG
```

On first launch the app opens a **setup window** that guides you through granting
Screen & System Audio Recording, Microphone, Calendar, Accessibility, and
Notifications — no need to dig through Settings.

### Why `setup-signing.sh` matters (persistent permissions)

macOS ties permission grants (Screen & Audio Recording, Accessibility) to the
app's **code-signing identity**. A plain build is *ad-hoc* signed — it has no
stable identity, so every rebuild looks like a brand-new app and those grants
silently reset (the checkbox stays on in System Settings, but the app can't use
the permission).

`./Scripts/setup-signing.sh` creates a **self-signed certificate** in a dedicated
keychain (the private key never leaves your Mac). `build-app.sh` then signs every
build with that one constant identity, so you **grant the permissions once and
they persist across all future local builds**. Run it once, then use
`install.sh`/`make-dmg.sh` as normal.

The released DMGs (built by GitHub Actions) are signed with this **same**
certificate — the p12 is stored in the repo's Actions secrets — so locally-built
and downloaded builds share one identity and permission grants carry across both.

> The certificate is self-signed (not Apple-notarized), so the first launch of
> each install still needs **System Settings → Privacy & Security → Open Anyway**
> (macOS 15/26) or **right-click → Open** (macOS 14). A fully clean-opening build
> with no first-launch step requires an Apple Developer ID + notarization.

## On-device transcription

- **WhisperKit** (`from: 1.0.0`) → on-device speech-to-text. `WhisperKitTranscriber`
  in `Transcriber.swift`. Uses **multilingual** models with **language
  auto-detection**, so English and Mandarin meetings (and reasonable
  code-switching) transcribe without manual configuration. On-screen name OCR and
  the silence-hallucination filter are Chinese-aware too.
- Models run the encoder/decoder on the **GPU** (`ModelComputeOptions`), avoiding
  the very slow first-time Apple Neural Engine compile.
- The model downloads at launch (with a progress bar) into an app-owned folder,
  `Application Support/MeetingAssistant/WhisperModels/` — not
  `~/Documents/huggingface`. Processing is gated until the model is ready.
- `Backends.swift` selects the real engine via `#if canImport(WhisperKit)` (inside
  MeetingKit, where the module is linked) and falls back to a stub otherwise.

Requires **full Xcode** to build (Metal/CoreML toolchain). Command Line Tools
alone can compile the pure-logic library + tests but not the WhisperKit deps.

### Long meetings on limited RAM

Meetings of any length (2 h+) transcribe within a flat memory budget, so a 16 GB
machine is fine: WhisperKit **VAD chunking** with a bounded worker count
processes long audio in voice-activity segments rather than holding it all at
once, and the two channels share one model load (the transcriber is an actor that
downloads/loads the model exactly once).

## Status

Core library, integrations, and app shell are implemented and building; the
unit-test suite is green. Active-speaker screen reading is best-effort and will
need per-platform tuning (it's the deliberately fragile part — the mic/system
split is the reliable speaker signal).
