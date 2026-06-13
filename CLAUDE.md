# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS menu-bar app (Swift + SwiftUI, deployment target **macOS 14**) that
watches the calendar, auto-captures Zoom/Meet/Teams meetings, and produces a
speaker-labeled transcript + AI summary — processed locally on Apple Silicon.

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

- Real ML deps (WhisperKit, MLX) require **full Xcode** for the Metal/CoreML
  compiler. Confirm Xcode is active: `xcode-select -p` should point inside
  `/Applications/Xcode.app`, not `/Library/Developer/CommandLineTools`.
- `Scripts/test.sh` exists as a fallback for running tests under **Command Line
  Tools only** (it injects the `Testing.framework` search path that SwiftPM
  doesn't add by default). Under full Xcode, prefer plain `swift test` — the
  script's hacks are unnecessary.

## Architecture

### Two SPM targets

- **`MeetingKit`** (library, `Sources/MeetingKit/`) — all domain logic, the
  Apple-framework integrations, and the ML backends. The test target imports it.
- **`MeetingAssistant`** (executable, `Sources/MeetingAssistant/`) — the SwiftUI
  `@main` app: menu bar, windows, settings, and the `AppState` coordinator.

### The defining principle: cheap live capture, heavy post-processing

`CaptureSession` is the **only** component that runs during a meeting, and it
stays deliberately light: it writes mic + system audio to separate files and
samples one video frame every few seconds. Everything expensive — transcription,
speaker fusion, summarization — runs **after** the meeting via `MeetingProcessor`,
reading from the files `CaptureSession` wrote. Preserve this split; don't move
transcription/LLM work into the live path.

### Pipeline

```
CalendarWatcher (EventKit) → MeetingDetector (NSWorkspace) → auto-start
  → CaptureSession  [LIVE: ScreenCaptureKit system audio + AVAudioEngine mic + SpeakerSampler frames]
  → MeetingRecording bundle on disk (MeetingStore)
  → MeetingProcessor: Transcriber → HallucinationFilter → SpeakerFuser → TranscriptFormatter → Summarizer
  → transcript.md + summary.md
```

### Speaker labeling has two signals with very different reliability

- **mic-vs-system audio split** → exact "Me" vs "remote" attribution; always works.
- **`SpeakerSampler`** (Vision OCR + CoreImage highlight detection) → attaches
  real names to remote speakers, but is **best-effort and fragile** (varies by
  app/version/theme/layout). It returns `nil` when unsure, and `SpeakerFuser`
  degrades to "Speaker". Treat any feature depending on named remote attribution
  as best-effort.

### ML backends are swappable behind protocols — go through `Backends`

`Transcribing` and `Summarizing` are protocols with real implementations
(`WhisperKitTranscriber`, `MLXSummarizer`, `ClaudeSummarizer`) and stubs
(`StubTranscriber`, `StubSummarizer`). The real WhisperKit/MLX implementations are
wrapped in `#if canImport(...)` and live in **MeetingKit**.

**Gotcha:** the app target does *not* link WhisperKit/MLX directly, so
`#if canImport(WhisperKit)` is always false there. Always select backends via
`Backends.makeTranscriber(...)` / `Backends.makeLocalSummarizer()` (in
`Sources/MeetingKit/Backends.swift`), which resolve inside MeetingKit. `Settings`
already routes through `Backends`; do the same for any new backend wiring.

### Pure logic vs. integrations (what's tested)

Pure, deterministic logic is unit-tested with **swift-testing** (`import Testing`,
`@Suite`/`@Test`/`#expect`) — `MeetingURLParser`, `SpeakerFuser`,
`HallucinationFilter`, `TranscriptFormatter`, `SummarizationPrompt`,
`SpeakerSampler.bestName`. The framework integrations (EventKit, ScreenCaptureKit,
AVAudioEngine, Vision) require real system access/permissions and are not unit
tested — verify those by running the app. When adding logic, keep it pure and
testable; follow TDD for it.

## Distribution / signing

There are no code-signing certificates on this machine, so builds are **ad-hoc
signed**. Consequences: Gatekeeper requires a one-time right-click → Open, and TCC
grants (Screen Recording, Mic, Calendar) are tied to the signature hash and may
reset on rebuild. A clean-opening, distributable DMG would need an Apple Developer
ID cert + notarization (notarytool is installed; the account is not).

## TCC permissions

The app needs Screen & System Audio Recording, Microphone, Calendar (full
access), Accessibility (window detection), and Notifications. Usage strings live
in `Resources/Info.plist`; `Sources/MeetingAssistant/Permissions.swift`
checks/prompts each. Screen Recording has no Info.plist key (granted via system
prompt). The app is intentionally **not sandboxed** (ScreenCaptureKit system audio
needs it off for a self-distributed build) — see `Resources/MeetingAssistant.entitlements`.
