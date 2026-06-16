# In-room speaker diarization — design

**Date:** 2026-06-16
**Status:** Approved (design)

## Problem

The app distinguishes speakers with two signals:

- **mic vs. system audio split** → exact "Me" (mic) vs. "remote" (system) attribution.
- **`SpeakerSampler`** (Vision OCR on the meeting video) → attaches real names to
  *remote* speakers who have on-screen tiles.

Neither handles the case where the user sits in a **physical room with several
other participants**. Everyone in the room is picked up by the single microphone,
so every in-room voice collapses into the `"Me"` label, and the in-room people
have no on-screen tile for OCR to read. The transcript becomes one long
monologue attributed to "Me".

## Goal

Diarize the **mic channel** into distinct speakers so the transcript reads:

- the user's own voice → `"Me"` (via a one-time voice enrollment),
- each other in-room voice → `"Speaker 2"`, `"Speaker 3"`, … numbered by order of
  first appearance.

Remote (system-audio) attribution is **unchanged**. The labels are anonymous and
distinct — no attempt to put real names on the other in-room people.

## Non-goals

- Naming the other in-room participants (anonymous "Speaker N" only).
- Real-time / live diarization. All diarization runs in post-processing.
- Diarizing the system (remote) channel — it already has its own attribution.
- Cloud diarization — rejected; the app's promise is local-only transcription.

## Engine choice

[**FluidAudio**](https://github.com/FluidInference/FluidAudio) (Apache-2.0):
on-device speaker diarization for Apple Silicon via CoreML/ANE.

- `OfflineDiarizerManager` — batch offline pipeline, the right fit for our
  post-meeting heavy processing.
- Input is `[Float]` at **16 kHz mono** — exactly what we already decode for
  WhisperKit (`AudioProcessor.loadAudio`), so no new audio plumbing.
- Returns segments with `startTime`, `endTime`, and a speaker id.
- `enrollSpeaker(withAudio:sourceSampleRate:named:)` — register the user's voice
  once as `"Me"`; the diarizer then labels matched segments `"Me"` directly, so we
  don't hand-roll embedding comparison.
- Minimum OS macOS 14 / iOS 17 — matches the app's deployment target.

Downloads CoreML models on first use (like WhisperKit). Models live under
`Application Support/MeetingAssistant/`.

## Architecture

Mirrors the existing swappable-transcription-backend pattern
(`Transcribing` / `WhisperKitTranscriber` / `StubTranscriber` / `Backends`).

### New seam: `Diarizing`

```swift
/// One contiguous run of speech attributed to a single diarized speaker.
public struct DiarizedSpan: Codable, Sendable, Equatable {
    public let start: TimeInterval    // seconds from meeting start
    public let end: TimeInterval
    public let speakerID: String      // FluidAudio speaker id; "Me" if matched to enrollment
}

public protocol Diarizing: Sendable {
    func prepare(progress: TranscribeProgressHandler?) async throws
    func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan]
}
```

- **`FluidAudioDiarizer`** — real implementation, an `actor`, wrapped in
  `#if canImport(FluidAudio)`, lives in **MeetingKit**. Loads/downloads models
  once (task-memoized, like `WhisperKitTranscriber`). On `diarize`, enrolls the
  user as `"Me"` from the stored enrollment audio (when present), then runs
  `OfflineDiarizerManager.process` on the mic samples and maps its result to
  `[DiarizedSpan]`.
- **`StubDiarizer`** — returns `[]`. An empty result makes fusion fall back to
  today's behavior (mic = `"Me"`).
- **`Backends.makeDiarizer(...)`** — resolves the implementation inside MeetingKit
  (the app target does not link FluidAudio, the same `canImport` gotcha that
  applies to WhisperKit).

### Enrollment model

```swift
/// A persisted one-time recording of the local user's voice, used to label
/// the user's diarized mic segments as "Me".
public struct MeEnrollment: Codable, Sendable, Equatable {
    public let audioFile: URL      // ~15s mic clip, 16 kHz mono, under Application Support
    public let recordedAt: Date
}
```

Stored under `Application Support/MeetingAssistant/`. A Settings flow records the
clip; the user can re-record or delete it.

### Pure fusion logic (new, unit-tested)

A pure function maps diarized spans onto the existing Whisper mic segments and
assigns display labels:

1. For each mic `TranscriptSegment`, find the `DiarizedSpan` whose
   `[start, end)` **contains** its midpoint. (Diarized spans are time ranges, so
   containment is the correct lookup — unlike the point-in-time OCR samples in
   `SpeakerSampler`, which are held until the next sample.) Segments whose
   midpoint falls in no span fall back to `"Me"`.
2. Assign labels: a span whose `speakerID == "Me"` → `"Me"`; every other distinct
   `speakerID` → `"Speaker 2"`, `"Speaker 3"`, … numbered by **order of first
   appearance** across the meeting (deterministic and stable).

`SpeakerFuser.fuse` gains a mic-side resolver (a `[DiarizedSpan]` plus the label
map) instead of the hard-coded `micLabel`. The system-channel branch is unchanged.

### Pipeline wiring

```
MeetingProcessor:
  Transcriber → HallucinationFilter            (existing)
  → if diarization enabled & enrolled:
        Diarizer.diarize(micAudioFile, enrollment)   (new)
        map spans → mic segment labels               (new, pure)
  → SpeakerFuser (mic labels from diarization OR "Me"; system unchanged)
  → TranscriptFormatter → transcript.md
```

Diarization reads the mic file already written by `CaptureSession`. **No live
capture changes.**

## Feature gating

- Setting: **"Identify multiple in-room speakers"**, default **off**.
- Enabling it **requires enrollment**; enabling triggers the one-time FluidAudio
  CoreML model download (reusing the existing transcription-style progress UI).
- When the setting is off, when no enrollment exists, when diarization fails, or
  when only one speaker is detected → mic segments are labeled `"Me"` exactly as
  today. Nothing regresses for the common solo-remote-meeting case.

## Error handling

- **Model download / load failure** → log, skip diarization, fall back to `"Me"`
  for all mic segments. Non-fatal (matches the best-effort posture of
  `SpeakerSampler`).
- **Diarization throws mid-run** → same fallback.
- **No enrollment** → feature cannot be enabled (UI gate); if somehow reached,
  fall back to `"Me"`.
- **Overlapping speech** → segment midpoint picks the dominant span; best-effort.
- **Hybrid meeting** (in-room mic + remote system) → mic diarized independently;
  system channel keeps its OCR/`"Speaker"` attribution. The two are namespaced
  separately (in-room others are `"Speaker N"`; remote unknowns stay `"Speaker"`).

## Testing

Unit-tested with **swift-testing** (`@Suite`/`@Test`/`#expect`), pure logic only:

- span → segment midpoint mapping: exact boundaries, gaps (no covering span),
  span held until next span.
- label assignment: enrolled `"Me"` mapping, `"Speaker N"` numbering by first
  appearance, stability across repeated speakers.
- `SpeakerFuser` integration: mic segments resolve via diarization; system
  segments unchanged; empty diarization → all `"Me"`.

FluidAudio integration (model download/load, actual diarization accuracy) is
**not** unit-tested — verified by running the app, consistent with how WhisperKit
and the other framework integrations are handled.

## Defaults (confirmed)

1. Non-user in-room speakers → `"Speaker 2"`, `"Speaker 3"`, … (remote unknowns
   stay `"Speaker"`).
2. Feature off by default; enabling requires enrollment.
3. Enrollment clip ~15 seconds.
