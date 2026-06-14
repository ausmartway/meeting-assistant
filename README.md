# Meeting Assistant

A native macOS menu-bar app that watches your calendar, automatically captures
meetings (Zoom, Google Meet, Microsoft Teams) when they start, and produces a
speaker-labeled transcript plus an AI summary with action items — all processed
locally on Apple Silicon.

Target hardware: MacBook Pro M1 Pro / 32 GB, macOS 14 (Sonoma)+.

## Design principle: cheap live capture, heavy post-processing

To stay responsive **during** a call, the app does almost nothing expensive while
recording. It only:

- writes the **microphone** (you) and **system audio** (everyone else) to two
  separate files, and
- samples one video frame every few seconds to note who's highlighted on screen.

All the heavy work — transcription, speaker labeling, summarization — runs
**after** the meeting ends, on the idle GPU. Your Mac stays free while you're in
the meeting.

## How it works

```
EventKit ─▶ CalendarWatcher ─▶ (start time) ─▶ MeetingDetector
   └▶ auto-start when a calendared meeting starts AND its app is running
CaptureSession  [LIVE: ScreenCaptureKit system audio + AVAudioEngine mic + frame sampling]
   ─▶ MeetingRecording bundle on disk
   ─▶ (you click Stop) ─▶ MeetingProcessor
        Transcriber ─▶ SpeakerFuser ─▶ Summarizer ─▶ MeetingStore
   ─▶ transcript.md + summary.md  ─▶ main window
```

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
| `Scripts/` | `test.sh`, `build-app.sh` |

Key components (all in `Sources/MeetingKit`):
`MeetingURLParser`, `CalendarWatcher`, `MeetingDetector`, `CaptureSession`,
`SpeakerSampler`, `Transcriber`, `SpeakerFuser`, `HallucinationFilter`,
`TranscriptFormatter`, `Summarizer` / `ClaudeSummarizer`, `MeetingProcessor`,
`MeetingStore`.

## Build & run

```sh
# Run the tests (works under Command Line Tools — no full Xcode needed)
./Scripts/test.sh

# Build a runnable, ad-hoc-signed .app and launch it
./Scripts/build-app.sh --run
```

`build-app.sh` produces `build/Meeting Assistant.app`. On first launch, open
**Settings → Permissions** and grant Screen & System Audio Recording,
Microphone, Calendar, Accessibility, and Notifications. For unsigned/dev builds
you may need to add the app manually under **System Settings → Privacy &
Security**.

## On-device ML

Real on-device ML is wired in and builds (requires **full Xcode** for the
Metal/CoreML toolchain — Command Line Tools alone can't compile these deps):

- **WhisperKit** (`from: 1.0.0`) → on-device transcription, encoder on the Apple
  Neural Engine. `WhisperKitTranscriber` in `Transcriber.swift`. Uses
  **multilingual** models with **language auto-detection**, so English and
  Mandarin meetings (and reasonable code-switching) transcribe without manual
  configuration. On-screen name OCR and the silence-hallucination filter are
  Chinese-aware too.
- **mlx-swift-examples / MLXLLM** (`from: 2.29.1`) → local summarization LLM
  (`Qwen2.5-3B-Instruct-4bit` by default). `MLXSummarizer` in `Summarizer.swift`.

`Backends.swift` selects the real engine via `#if canImport` (inside MeetingKit,
where the modules are linked) and falls back to the stubs if a backend is ever
removed. Models download on first use, then run fully offline.

The **Claude API** summarizer (`ClaudeSummarizer`) is the opt-in alternative —
set an API key in Settings and pick the Claude engine. Audio always stays
on-device; only transcript text is sent when you opt into Claude.

### Long meetings on limited RAM

Meetings of any length (2 h+) work within a flat memory budget, so a 16 GB
machine is fine:

- **Transcription** uses WhisperKit VAD chunking with a bounded worker count, so
  long audio is processed in voice-activity segments rather than all at once.
- **Summarization** is **map-reduce** (`SummaryRunner` + `TranscriptChunker`):
  the transcript is split into bounded chunks, each summarized independently
  (fresh LLM context, capped output), then the chunk-summaries are reduced — and
  reduced again hierarchically if needed. Each model call sees a bounded amount
  of text, so peak memory doesn't grow with meeting length. The local
  `MLXSummarizer` is an actor that loads the model once and reuses it across all
  chunk calls.

## Status

Core library, integrations, app shell, and **real on-device transcription +
summarization** are all implemented and building; the unit-test suite is green.
Active-speaker screen reading is best-effort and will need per-platform tuning
(it's the deliberately fragile part — the mic/system split is the reliable
speaker signal).
