# Auto-route transcription engine by detected language

**Date:** 2026-06-17
**Status:** Proposed (follow-up to PR #3 — Parakeet opt-in engine)
**Depends on:** `FluidAudioTranscriber`, `TranscriptionEngine`, `Backends.makeTranscriber(engine:)` (already on branch `model-finetune`)

## Problem

Parakeet is ~100× faster than WhisperKit on English speech but **cannot transcribe
Mandarin** (FluidAudio's `Language` set is European-only; see
`docs/decisions/2026-06-17-transcription-engine.md`). Today the user picks one
engine globally, so they can't get Parakeet's speed without losing Mandarin.

**Goal:** an **`auto`** engine that detects each channel's language and routes it to
the right backend — Parakeet for English/European, WhisperKit for Mandarin/other —
capturing the speed win with **no Mandarin regression**.

## Decisions

- **Per-channel routing.** Detect language on the mic and system audio
  independently and choose the engine for each. This fits the architecture
  (`Transcribing.transcribe` is already called once per channel) and handles
  bilingual meetings (e.g. user speaks English on mic, remote speaks Mandarin on
  system).
- **Routing rule:** confidently-detected English or a Parakeet-supported European
  language → **Parakeet `.v3`** (multilingual, passed the detected language as a
  hint for script-aware token filtering). CJK, any other script, or low-confidence
  detection → **WhisperKit** (safe multilingual default).
- **Conservative on uncertainty:** below a confidence threshold, or on any
  detection error, fall back to WhisperKit. Wrong-but-multilingual beats fast-but-
  garbage.
- **`auto` becomes the default engine** once shipped (it degrades to WhisperKit for
  everything Parakeet can't do, so it's strictly safer than a Parakeet default and
  faster than a WhisperKit default for English/European audio). WhisperKit-only and
  Parakeet-only remain explicit choices in Settings.

## Architecture

A new `AutoRoutingTranscriber` implements `Transcribing` by composing a language
detector and the two existing engines. Per `transcribe(audioFile:channel:)` call:

```
detect language of this channel's audio
  → EngineRouter decides: .parakeet(languageCode) | .whisperKit
  → delegate to the chosen engine (Parakeet gets the language hint)
  → return its [TranscriptSegment] (channel + timestamps preserved as today)
```

### Components

1. **`LanguageDetecting` protocol** (MeetingKit)
   ```swift
   public struct DetectedLanguage: Sendable, Equatable {
       public let code: String      // ISO-ish code from the detector, e.g. "en", "zh"
       public let confidence: Double // 0...1
   }
   public protocol LanguageDetecting: Sendable {
       func detectLanguage(audioFile: URL) async throws -> DetectedLanguage?
   }
   ```
   - Real impl: `WhisperKitTranscriber` already loads the multilingual Whisper
     model; expose its language-detection pass (WhisperKit's `detectLanguage`)
     behind this protocol. Detection is a short encoder pass — seconds, not minutes.
   - A `nil` return (couldn't decide) routes to WhisperKit.

2. **`EngineRouter`** — *pure, unit-tested* (MeetingKit, no framework import)
   ```swift
   public enum RoutedEngine: Sendable, Equatable {
       case whisperKit
       case parakeet(languageCode: String)
   }
   public enum EngineRouter {
       /// Codes Parakeet `.v3` supports (FluidAudio `Language`): en + ~European.
       public static let parakeetLanguages: Set<String> = [
           "en","es","fr","de","it","pt","ro","nl","da","sv","fi","hu","et",
           "lv","lt","mt","pl","cs","sk","sl","hr","bs","ru","uk","be","bg","sr","el"
       ]
       public static func route(
           detected: DetectedLanguage?,
           threshold: Double = 0.5
       ) -> RoutedEngine {
           guard let d = detected, d.confidence >= threshold,
                 parakeetLanguages.contains(d.code) else { return .whisperKit }
           return .parakeet(languageCode: d.code)
       }
   }
   ```
   This is the one piece of real logic and gets full TDD (English→Parakeet,
   Spanish→Parakeet, "zh"→WhisperKit, low-confidence→WhisperKit, unknown
   code→WhisperKit, nil→WhisperKit).

3. **`FluidAudioTranscriber` extension** — accept a language hint and use `.v3`
   - Add an internal/public method the router can call with the detected code, e.g.
     `transcribe(audioFile:channel:languageCode:progress:)`, mapping the code to
     `FluidAudio.Language` (the code→Language map lives here, behind
     `#if canImport(FluidAudio)`). For `auto`, construct the Parakeet engine with
     `version: .v3` so the hint is honored. (The standalone Parakeet engine keeps
     using `.v2`/English.)

4. **`AutoRoutingTranscriber: Transcribing`** (MeetingKit)
   - Holds a `LanguageDetecting`, a WhisperKit transcriber, and a Parakeet `.v3`
     transcriber.
   - `prepare`: prepares the detector/WhisperKit (always needed); Parakeet is
     prepared lazily on first European/English channel (avoid paying its
     download/load for an all-Mandarin user).
   - `transcribe`: detect → `EngineRouter.route` → delegate. `setConcurrentWorkers`
     forwards to WhisperKit.
   - Orchestration is testable with a stub detector + stub engines (assert the
     right engine is called for each detected language).

5. **`TranscriptionEngine.auto`** + `Backends.makeTranscriber(engine: .auto)` builds
   an `AutoRoutingTranscriber`. Settings picker gains an "Automatic (recommended)"
   option; `auto` becomes the persisted default.

## Data flow / integrity

Routing is invisible downstream: each channel still returns `[TranscriptSegment]`
tagged with its `channel` and per-segment timestamps, so `SpeakerFuser`, the
mic/system "Me vs remote" split, and the speaker timeline are unchanged.

## Error handling

- Detection throws / returns nil / low confidence → WhisperKit (never blocks).
- Chosen engine throws → propagate as today (the existing `process` catch handles
  it; cancellation still works via the Task checkpoints).

## Performance / cost (note, not blocker)

`auto` keeps the WhisperKit model resident (for detection + non-European channels);
Parakeet `.v3` loads only when a channel routes to it. Worst case (bilingual
meeting) both models are resident — heavier on 16 GB Macs. Detection adds a few
seconds per channel; negligible against a multi-minute transcription, and a large
net win whenever a channel routes to Parakeet.

## Testing

- **`EngineRouter`** — pure, full TDD (the cases above).
- **`AutoRoutingTranscriber`** — unit test with a stub `LanguageDetecting` and stub
  WhisperKit/Parakeet transcribers asserting per-channel engine selection
  (English→Parakeet, Mandarin→WhisperKit, low-confidence→WhisperKit, detector
  error→WhisperKit).
- **Real detection + engines** — verified by running the app and by `TranscribeBench`
  (extend it with an `auto` mode) on the existing English and Mandarin recordings:
  the English clip must route to Parakeet (fast), the Mandarin clip to WhisperKit
  (accurate).

## Out of scope

- Code-switching *within* a single channel (detection picks the dominant language;
  acceptable limitation — note it).
- Re-detecting mid-stream / streaming.
- Verifying Parakeet `.v3` accuracy on each European language (we trust the
  language-hinted path; revisit if a specific language reads poorly).

## Open question to settle during planning

- **Confidence threshold value** (default 0.5) — tune against real recordings; a
  too-low threshold risks routing borderline Mandarin to Parakeet (garbage), so err
  high.
