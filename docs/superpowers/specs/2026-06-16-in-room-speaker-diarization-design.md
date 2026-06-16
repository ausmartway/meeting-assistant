# In-room speaker diarization — design

**Date:** 2026-06-16
**Status:** Approved (design); **extended 2026-06-16 — see "Extension: local speaker library" at the end, which supersedes the narrow "Me-only enrollment" parts below.**

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

---

# Extension: local speaker library (approved 2026-06-16)

This extends the feature from "match only the enrolled user" to a **local,
cross-meeting speaker library**. It supersedes the "Me-only enrollment" mechanics
above (the `enrollSpeaker`/single-`MeEnrollment` matching). The pipeline shape,
the `Diarizing` seam, and Tasks 1–6 are unchanged; the matching/labeling layer and
the app UI grow.

## New goals

- **Recognize known people by voice in every meeting.** Each meeting's voice
  clusters are matched against a saved library; confident matches get the stored
  name, the rest stay `"Speaker 2"`, `"Speaker 3"`, ….
- **Name anonymous speakers, persistently.** In a meeting's transcript the user
  can rename a `"Speaker N"`; that rewrites the transcript **and** saves that
  voice's print to the library, so the same person is auto-named next time.
- **"Me" is just a known speaker** (`isMe == true`), enrolled by reading an
  on-screen script during initial setup (and re-doable in Settings).

## Data model & storage

```swift
/// A person the app can recognize by voice across meetings.
public struct KnownSpeaker: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String        // "Me", "Sam", …
    public var isMe: Bool
    public var embedding: [Float]   // voiceprint centroid
    public var updatedAt: Date
}
```

- **`SpeakerLibrary`** — loads/saves `[KnownSpeaker]` to
  `Application Support/MeetingAssistant/speakers.json` (URL injected for tests).
  API: `all()`, `me`, `upsert(name:embedding:isMe:)`, `rename(id:to:)`,
  `delete(id:)`.
- **Per-meeting speaker map** — saved inside the recording bundle
  (`speakers.json` next to `transcript.md`): `clusterID → embedding` and
  `clusterID → resolved display label`. This lets a later rename recover the
  voiceprint and rewrite the transcript without re-diarizing.

## Diarizer returns voiceprints

The engine stops doing user-matching. `Diarizing.diarize` now returns:

```swift
public struct DiarizationOutcome: Sendable, Equatable {
    public let spans: [DiarizedSpan]            // speakerID = raw cluster id
    public let embeddings: [String: [Float]]    // cluster id → centroid voiceprint
}
```

`FluidAudioDiarizer` simply surfaces FluidAudio's `result.segments` +
`result.speakerDatabase` (cluster → centroid); the `matchEnrolledSpeaker` logic is
removed from it. `StubDiarizer` returns an empty outcome.

## Recognition & labeling (pure, unit-tested)

- **`VoiceMatch.cosineDistance(_:_:) -> Float`** — pure, in MeetingKit (so
  recognition is testable without FluidAudio). Smaller = more similar.
- **`SpeakerRecognizer.resolve(outcome:library:threshold:) -> [String: String]`** —
  maps each cluster id to a display label: nearest `KnownSpeaker` with cosine
  distance ≤ a **conservative** threshold → that name; otherwise `"Speaker 2"`,
  `"Speaker 3"`, … numbered by first appearance, with known/`"Me"` names excluded
  from the numbering. Supersedes `DiarizationLabeler`. Weak (near-threshold)
  matches deliberately stay `"Speaker N"` rather than risk a wrong name.

## Pipeline & fusion changes

- `MeetingProcessor`: diarize mic → `SpeakerRecognizer.resolve` against the
  library → fuse using the resolved `clusterID → label` map → persist the
  per-meeting speaker map (embeddings + labels) in the bundle. Best-effort: any
  diarization/recognition failure degrades to today's `"Me"`.
- `SpeakerFuser`: instead of computing labels itself, it takes the resolved
  `clusterID → label` map plus the spans and applies them to mic segments
  (midpoint containment; fallback `"Me"`). System channel unchanged.

## Rename flow

- A pure function rewrites a transcript's speaker labels (`"Speaker 2:" → "Sam:"`).
- Renaming a speaker in the transcript pane: rewrite `transcript.md`, update the
  per-meeting map's label, and `upsert` that cluster's embedding into the library
  under the new name (so future meetings recognize them). Renaming to an existing
  known name merges/updates that speaker's voiceprint.

## Enrollment by reading a script

- A fixed on-screen passage; record ~15–20 s; diarize the clip; take the dominant
  speaker's embedding; `upsert` it as the `isMe` `KnownSpeaker`.
- Presented in **onboarding** (initial setup) and re-doable in Settings.

## UI

- **Onboarding:** a "Teach the app your voice" step — show the script, Record,
  confirm enrolled.
- **Transcript detail pane:** a **Speakers** section listing the meeting's
  speakers with editable name fields; saving rewrites the transcript and saves the
  voiceprint. Recognized known speakers appear already named.
- **Settings:** manage the library (list, rename, delete known speakers),
  re-enroll "Me". The "Identify multiple in-room speakers" toggle remains; it now
  also gates auto-recognition of known speakers.

## Testing

Pure logic unit-tested (swift-testing): `VoiceMatch.cosineDistance`,
`SpeakerLibrary` upsert/match/rename round-trips, `SpeakerRecognizer.resolve`
(known match, conservative threshold, `"Speaker N"` numbering, `"Me"`),
transcript-relabel rewrite, per-meeting map persistence. FluidAudio engine and all
SwiftUI/AVFoundation pieces are verified by running the app.

## Privacy

Voiceprints (float vectors) and names never leave the device — stored under
Application Support alongside the existing local models. No raw enrollment audio is
retained beyond what's needed to compute the embedding (the clip may be deleted
after enrollment).
