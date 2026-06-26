# OCR speaker-name robustness — design

**Date:** 2026-06-20
**Status:** Approved (brainstorming)
**Requirement:** Strengthens R10b (best-effort on-screen names) — accuracy/robustness
only, no new user-facing surface.

## Problem

`SpeakerSampler` reads the active remote speaker's name off a captured video frame
via Vision OCR. Three weaknesses make it fragile:

1. **Single-frame decisions.** Each `sample()` call picks a name from one frame
   independently. One misread frame yields a wrong name that then "holds until the
   next sample" in `SpeakerFuser` (`activeSpeaker(at:)`), polluting a stretch of
   the transcript.
2. **No name normalization/dedup.** "John Smith", "John Smith (Host)", and an OCR
   slip like "J0hn Smith" become three distinct speakers.
3. **Vision confidence ignored.** `recognizeName` takes `topCandidates(1).first?.string`
   and discards `.confidence`, so low-confidence garbage is accepted as a name.

## Principles preserved

- **Cheap live capture, heavy post-processing.** `SpeakerSampler` still runs
  per-frame in the live path. The new multi-frame voting runs in
  `MeetingProcessor` (post-processing), not during capture.
- **Pure logic is unit-tested (swift-testing, TDD).** The two new modules are pure
  and fully tested. The `SpeakerSampler` change is integration-layer (Vision) and
  verified by running the app, per the project's testing policy.

## Components

### 1. Confidence thresholding — `SpeakerSampler.recognizeName` (integration)

- Collect `(string, confidence)` from `topCandidates(1)` instead of just the string.
- Drop candidates below a threshold constant `nameConfidenceThreshold = 0.4`
  before handing the surviving strings to `bestName`.
- Low-confidence reads → no surviving candidates → `nil` → `SpeakerFuser` degrades
  to "Speaker" (honest) instead of asserting a confident-wrong name.
- `bestName(from: [String])` keeps its signature and existing tests; filtering
  happens upstream of it.
- Not unit-tested (Vision needs real system access); verified by running the app.

### 2. Name normalization — new pure module `SpeakerNameNormalizer` (MeetingKit)

```swift
enum SpeakerNameNormalizer {
    /// Cleaned display name, or nil if nothing meaningful remains.
    static func displayName(_ raw: String) -> String?
    /// Folding used ONLY for grouping (not display).
    static func canonicalKey(_ name: String) -> String
}
```

- `displayName`: trims; collapses internal whitespace to single spaces; strips
  trailing role/parenthetical markers in English + Chinese — `(Host)`, `(You)`,
  `(Guest)`, `(Co-host)`, `(Me)`, `（主持人）`, etc. (case-insensitive); returns
  `nil` if the result is empty or too short to be a name.
- `canonicalKey`: lowercased, diacritics-folded, whitespace removed — so
  "John Smith" and "john  smith" share a key.
- `SpeakerSampler` applies `displayName` to its OCR result so persisted
  `SpeakerSample`s are already clean.

### 3. Multi-frame voting — new pure module `SpeakerTimelineConsolidator` (MeetingKit)

```swift
enum SpeakerTimelineConsolidator {
    static func consolidate(_ timeline: SpeakerTimeline) -> SpeakerTimeline
}
```

Two ordered steps over the time-sorted samples:

- **A. Variant snapping by frequency.** Group non-nil samples by
  `canonicalKey`. Within each cluster the most-frequent `displayName` variant wins
  (ties broken by first-seen for determinism) and rewrites every member of the
  cluster to that winner. Folds whitespace/role/case variants to one label.
- **B. Isolated-outlier suppression.** A name appearing in a single sample whose
  *immediate* neighbors before and after are the *same different* name is treated
  as a misread and replaced by that neighbor name. If the neighbors disagree (or
  either is missing/`nil`), the lone read is set to `nil` rather than trusted.
  Neighbors are the directly-adjacent samples (the check does not reach across
  `nil` gaps), which keeps suppression conservative. Leaning toward suppression is
  intentional: OCR is the fragile signal, mic-vs-system is the reliable one.
  Trade-off accepted: a genuine brief speaker switch between two samples may be
  smoothed away.

**Out of scope:** folding arbitrary OCR character-confusions (0↔O, 1↔l↔I) into a
shared cluster — too risky. Those misreads are instead caught as isolated outliers
in Step B.

Timestamps are preserved; only `speakerName` values change. Output is a new
`SpeakerTimeline` (immutable input).

## Data flow

```
Live (unchanged structurally):
  frame → SpeakerSampler.sample
            → recognizeName (NEW: confidence filter)
            → bestName
            → displayName (NEW)
            → SpeakerSample{timestamp, speakerName}
  → SpeakerTimeline persisted in MeetingRecording

Post-processing (MeetingProcessor, before fusion):
  recording.timeline
    → SpeakerTimelineConsolidator.consolidate   (NEW)
    → SpeakerFuser.fuse(timeline: consolidated, …)
```

## Error handling / edge cases

- Empty timeline → consolidate returns it unchanged.
- All-nil timeline → unchanged.
- Single sample → Step A no-op; Step B no-op (no neighbors).
- `displayName` returning nil for an existing sample → sample becomes a nil read
  (degrades to "Speaker"), never crashes.

## Testing

New swift-testing suites (pure):

- `SpeakerNameNormalizer` — whitespace collapse, role-suffix stripping (EN + zh),
  nil for empty/too-short, `canonicalKey` folding (case, diacritics, whitespace).
- `SpeakerTimelineConsolidator` — variant snapping picks most-frequent winner;
  tie-break determinism; isolated outlier replaced by agreeing neighbors; isolated
  outlier nilled when neighbors disagree; empty/all-nil/single-sample pass-through;
  timestamps preserved.

`SpeakerSampler` confidence threshold + `MeetingProcessor` wiring verified by
running the app (no unit test — framework integration).

## Build order (TDD each)

1. `SpeakerNameNormalizer` (+ suite)
2. `SpeakerTimelineConsolidator` (+ suite; depends on normalizer)
3. Wire `consolidate` into `MeetingProcessor` before `SpeakerFuser.fuse`
4. Confidence threshold + `displayName` into `SpeakerSampler.recognizeName`
