# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Product requirements live in [`REQUIREMENTS.md`](REQUIREMENTS.md)** — the
> explicit and implicit requirements for *what* the app must do and *how it must
> feel*. Read it before changing behavior or UI; this file covers *how the code is
> organized*. Keep `REQUIREMENTS.md` updated when requirements change.

## What this is

A native macOS menu-bar app (Swift + SwiftUI, deployment target **macOS 14**) that
watches the calendar, prompts to capture Zoom/Meet/Teams meetings, and produces a
speaker-labeled transcript — transcribed locally on Apple Silicon. (Summarization
was intentionally removed; this app only transcribes.)

## Commands

```sh
swift build                      # build everything (library + app)
swift build --target MeetingKit  # build just the core library
swift test                       # run all unit tests (swift-testing)
swift test --filter SpeakerFuser # run one suite by @Suite name
./Scripts/build-app.sh [--run]   # release build → ad-hoc-signed build/Meeting Assistant.app
./Scripts/make-dmg.sh            # build the app and package build/MeetingAssistant.dmg
```

### Toolchain note (important)

- WhisperKit requires **full Xcode** for the Metal/CoreML compiler. Confirm Xcode
  is active: `xcode-select -p` should point inside `/Applications/Xcode.app`, not
  `/Library/Developer/CommandLineTools`.
- `Scripts/test.sh` exists as a fallback for running tests under **Command Line
  Tools only** (it injects the `Testing.framework` search path that SwiftPM
  doesn't add by default). Under full Xcode, prefer plain `swift test` — the
  script's hacks are unnecessary.

## Architecture

### Two SPM targets

- **`MeetingKit`** (library, `Sources/MeetingKit/`) — all domain logic, the
  Apple-framework integrations, and the transcription backend. The test target imports it.
- **`MeetingAssistant`** (executable, `Sources/MeetingAssistant/`) — the SwiftUI
  `@main` app: menu bar, windows, settings, and the `AppState` coordinator.

### The defining principle: cheap live capture, heavy post-processing

`CaptureSession` is the **only** component that runs during a meeting, and it
stays deliberately light: it writes mic + system audio to separate files and
samples one video frame every few seconds. Everything expensive — transcription
and speaker fusion — runs **after** the meeting via `MeetingProcessor`, reading
from the files `CaptureSession` wrote. Preserve this split; don't move
transcription work into the live path.

### Pipeline

```
CalendarWatcher (EventKit) → MeetingDetector (NSWorkspace) → "Start recording?" notification → user taps Start
  → CaptureSession  [LIVE: ScreenCaptureKit system audio + AVAudioEngine mic + SpeakerSampler frames]
  → MeetingRecording bundle on disk (MeetingStore)
  → MeetingProcessor: Transcriber → HallucinationFilter → SpeakerFuser → TranscriptFormatter
  → transcript.md
```

### Speaker labeling has two signals with very different reliability

- **mic-vs-system audio split** → exact "Me" vs "remote" attribution; always works.
- **`SpeakerSampler`** (Vision OCR + CoreImage highlight detection) → attaches
  real names to remote speakers, but is **best-effort and fragile** (varies by
  app/version/theme/layout). It returns `nil` when unsure, and `SpeakerFuser`
  degrades to "Speaker". Treat any feature depending on named remote attribution
  as best-effort.

### Languages

Transcription has three `TranscriptionEngine` choices (resolved via
`Backends.makeTranscriber(engine:…)`): **`.auto`** (the default), **`.whisperKit`**,
and **`.parakeet`**. `.auto` is `AutoRoutingTranscriber`: it detects each channel's
language (WhisperKit's `detectLanguage`, scored via `EngineRouter.probability` since
WhisperKit returns log-probs) and routes English/European → Parakeet `.v3`
(language-hinted, ~100× faster) and Mandarin / other / uncertain → WhisperKit. The
routing policy is the pure `EngineRouter`; **Parakeet is English/European-only and
cannot do Mandarin** (its `Language` set has no CJK), which is why CJK always falls
back to WhisperKit (see `docs/decisions/2026-06-17-transcription-engine.md`).
WhisperKit is **multilingual with auto-detection** (English + Mandarin):
`TranscriptionModel` cases are multilingual Whisper variants (no `.en`), and
`WhisperKitTranscriber` passes `DecodingOptions(language: nil, detectLanguage: true)`.
Chinese-awareness also lives in `SpeakerSampler` (OCR
`recognitionLanguages` include `zh-Hans`/`zh-Hant`; `bestName` filters CJK UI
words) and `HallucinationFilter` (Mandarin stock phrases + CJK punctuation
stripping). The **UI is English-only** — no string localization yet.

### Transcription backend is swappable behind a protocol — go through `Backends`

`Transcribing` is a protocol with a real implementation (`WhisperKitTranscriber`,
an actor) and a stub (`StubTranscriber`). The real WhisperKit implementation is
wrapped in `#if canImport(WhisperKit)` and lives in **MeetingKit**.

**Gotcha:** the app target does *not* link WhisperKit directly, so
`#if canImport(WhisperKit)` is always false there. Always select the backend via
`Backends.makeTranscriber(...)` (in `Sources/MeetingKit/Backends.swift`), which
resolves inside MeetingKit. `AppState`/`Settings` already route through `Backends`.

WhisperKit specifics: GPU compute (`ModelComputeOptions(.cpuAndGPU)`) avoids the
slow first-time ANE compile; models download to
`Application Support/MeetingAssistant/WhisperModels/`; the transcriber is an actor
that memoizes the load `Task` so concurrent channels share one download/load.

### Pure logic vs. integrations (what's tested)

Pure, deterministic logic is unit-tested with **swift-testing** (`import Testing`,
`@Suite`/`@Test`/`#expect`) — `MeetingURLParser`, `SpeakerFuser`,
`HallucinationFilter`, `TranscriptFormatter`, `WhisperTextCleaner`,
`SpeakerSampler.bestName`, `Meeting.adHoc`. The framework integrations (EventKit, ScreenCaptureKit,
AVAudioEngine, Vision) require real system access/permissions and are not unit
tested — verify those by running the app. When adding logic, keep it pure and
testable; follow TDD for it.

## Distribution / signing

There is no Apple Developer ID cert on this machine, so builds are not notarized.
Gatekeeper blocks the first launch — on **macOS 15/26** the user must approve it
via **System Settings → Privacy & Security → Open Anyway** (the old right-click →
Open button was removed in macOS 15; it still works on **macOS 14**). A
clean-opening, distributable DMG would need an Apple Developer ID + notarization
(notarytool is installed; the account is not).

**Signing identity (important for TCC).** macOS anchors TCC grants (Screen
Recording, Accessibility) to the code-signing identity. *Ad-hoc* signing has no
stable identity, so grants silently reset on every rebuild. `Scripts/build-app.sh`
therefore prefers a **stable self-signed certificate**: run
`Scripts/setup-signing.sh` once — it creates the cert in a dedicated keychain
(`~/Library/Keychains/meeting-assistant-signing.keychain-db`, password in
`~/.config/meeting-assistant/`, both outside the repo) and `build-app.sh` signs by
that identity's hash with `--keychain`, giving a constant designated requirement
(`certificate root = H"…"`) so grants persist across local builds. With no cert
set up, it falls back to ad-hoc. **CI release builds use the same certificate**:
the p12 + password live in the GitHub Actions secrets `CODESIGN_P12_BASE64` /
`CODESIGN_P12_PASSWORD`, imported into a throwaway keychain by the release
workflow, so locally-built and CI-built apps share one identity and TCC grants
carry across both. (Still not Apple-notarized — first launch needs Open Anyway.)

## TCC permissions

The app needs Screen & System Audio Recording, Microphone, Calendar (full
access), Accessibility (window detection), and Notifications. Usage strings live
in `Resources/Info.plist`; `Sources/MeetingAssistant/Permissions.swift`
checks/prompts each. Screen Recording has no Info.plist key (granted via system
prompt). The app is intentionally **not sandboxed** (ScreenCaptureKit system audio
needs it off for a self-distributed build) — see `Resources/MeetingAssistant.entitlements`.
