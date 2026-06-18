# Tiered retention & storage management — design

**Requirements:** R26 (tiered retention), N11 (manageable storage), R20 (manual delete, existing)
**Date:** 2026-06-18
**Status:** Approved, ready for implementation plan

## Problem

Meeting recordings are large — the heavy artifacts on disk are `mic.wav` +
`system.wav` (audio). Sampled video frames are **not** persisted (only the OCR'd
name timeline lives in `recording.json`), so audio is the only thing that grows
unbounded. Transcripts (`transcript.md`) and metadata (`recording.json`,
`speakers.json`) are tiny.

Today the only cleanup is manual per-recording delete (R20). Recordings accumulate
in a folder the user can't see. We want **tiered retention**: heavy audio ages out
after a few days; lightweight transcripts are kept far longer; and the user can see
and reclaim space.

## Decisions (settled in brainstorming)

- **Two independent retention windows**, both user-configurable in Settings with
  reasonable defaults:
  - **Media (audio)**: default **7 days**, then the WAVs are deleted.
  - **Transcript (whole bundle)**: default **1 year**, then the entire bundle is deleted.
  - Each window supports a **"Never"** option (maps to `nil` = never expire).
- **Sweep timing:** on app launch, then on a ~24h repeating timer while running.
- **Never sweep an active meeting:** a meeting currently recording or transcribing
  is excluded from the sweep by id.
- **Storage UI lives in both places:** retention controls + total in Settings →
  Storage; a compact "X GB used" indicator in the main window footer.
- **Manual delete (R20) is unchanged** — still removes everything immediately.

## Invariant: the sweep never deletes voiceprints

There are two completely separate voiceprint stores:

1. **Global `SpeakerLibrary`** → `<AppSupport>/MeetingAssistant/speakers.json`
   (a **root-level file**, not inside any meeting bundle). Holds every
   recognized/named voiceprint (`KnownSpeaker`: name + isMe + embedding). Renaming
   a speaker `upsert`s the fingerprint here. This is the durable, cross-meeting
   identity store that powers R9 (auto-recognition in future meetings).
2. **Per-meeting `MeetingSpeakerMap`** → `<meeting-id>/speakers.json` — that
   meeting's cluster embeddings + labels, lives *inside* the bundle.

The sweep MUST preserve recognized voices' fingerprints independent of meetings:

1. The sweep **only operates on directories that contain a `recording.json`** (a
   valid meeting bundle). The root-level global `speakers.json` is a file, not a
   bundle directory — structurally untouchable by the sweep.
2. **Media expiry** deletes *only* `mic.wav` + `system.wav`. It deliberately
   **keeps** the per-meeting `speakers.json` (so renaming still teaches the
   library), `recording.json`, and `transcript.md`.
3. On **full-bundle deletion** (transcript expiry), the global `SpeakerLibrary` is
   never in a meeting folder, so all recognized attendees' fingerprints survive.
   The only loss is *unnamed* clusters' embeddings from that one meeting — acceptable.

## Architecture

### 1. `RetentionPolicy` (pure logic, MeetingKit, TDD core)

```swift
public struct RetentionPolicy: Equatable, Sendable {
    public var mediaMaxAge: TimeInterval?       // nil = never expire audio
    public var transcriptMaxAge: TimeInterval?  // nil = keep bundle forever

    public static let `default` = RetentionPolicy(
        mediaMaxAge: 7 * 24 * 3600,
        transcriptMaxAge: 365 * 24 * 3600
    )

    public func shouldExpireMedia(recordedAt: Date, now: Date) -> Bool
    public func shouldDeleteBundle(recordedAt: Date, now: Date) -> Bool
}
```

- Pure decision functions, fully unit-testable with injected `now`.
- `nil` window → corresponding action never fires.
- Bundle deletion takes precedence (if a bundle is past `transcriptMaxAge`, it's
  deleted whole rather than just having media expired).

### 2. `MeetingStore` additions

- `expireMedia(meetingID:)` — delete just `mic.wav` + `system.wav` (idempotent;
  no-op if already gone). Leaves all other bundle files intact.
- `hasAudio(meetingID:)` — `true` iff both WAVs exist. Drives the UI's
  audio-present vs. audio-expired state.
- `bundleSize(meetingID:) -> Int64` and `totalSize() -> Int64` — bytes on disk for
  the "space used" view.
- `sweep(policy:now:activeIDs:) -> RetentionSweepResult` — iterate **bundle
  directories only** (those containing `recording.json`), skip `activeIDs`, apply
  the policy (delete-bundle takes precedence over expire-media), return a summary
  (`bundlesDeleted`, `mediaExpired`, `bytesReclaimed`). The sweep reads
  `recordedAt` from each `recording.json`.

The bundle-directory guard (only act on dirs with a `recording.json`) is the
structural protection for the root-level global `speakers.json`.

### 3. Settings

New persisted preferences in `AppSettings` (UserDefaults), exposed as a
`RetentionPolicy`:

- `mediaRetentionDays: Int?` (nil = Never) — default 7.
- `transcriptRetentionDays: Int?` (nil = Never) — default 365.
- A computed `retentionPolicy: RetentionPolicy` built from the two.
- Picker options offered as friendly choices (e.g. 3/7/14/30 days, 90/180/365
  days / 1 year, and Never) rather than free-form numbers.

### 4. AppState

- On launch and on a 24h `Timer`, call
  `store.sweep(policy: settings.retentionPolicy, now: Date(), activeIDs:)` where
  `activeIDs` = the meeting(s) currently recording or transcribing.
- After a sweep, refresh `recordings` (so any fully-deleted bundle drops out) and
  publish the new total size.
- "Clean up now" in Settings triggers an immediate sweep.

### 5. UI

- **Recording detail pane:** when `hasAudio` is false, show an **"Audio cleared to
  save space"** note, and disable **Make Transcript Again** with that explanation
  (it needs the WAVs). Never a silent failure (R26). The transcript itself remains
  fully readable, copyable, and exportable.
- **Settings → Storage section:** total space used, the two retention pickers
  (each with a "Never" option), and a **"Clean up now"** button.
- **Main window footer:** compact "X GB used" line in the recordings sidebar.

## Error handling

- All deletions are best-effort and idempotent (N3): a failed/again-deleted file is
  not fatal; the sweep continues to the next bundle.
- The sweep never throws out of the launch path — failures are logged and skipped.
- `activeIDs` exclusion guarantees no in-flight recording or transcript is touched
  (N4: no data loss / no premature deletion).

## Testing

Pure / unit-tested (swift-testing), following TDD:

- `RetentionPolicy.shouldExpireMedia` / `shouldDeleteBundle` across boundaries
  (just-under, exactly-at, well-past, `nil` = Never).
- `MeetingStore.sweep` against a temp-dir fixture: media-only expiry keeps the
  transcript + `speakers.json`; full expiry removes the bundle; `activeIDs` are
  skipped; a non-bundle root-level file (simulating the global `speakers.json`) is
  never touched; `bytesReclaimed` is accurate.
- `MeetingStore.hasAudio` / `expireMedia` idempotence.
- `MeetingStore.totalSize` / `bundleSize` on a known fixture.

Verified by running (framework/UI per N8): Settings → Storage controls take effect,
footer total updates, "Make Transcript Again" disables with the explanation when
audio is expired, "Clean up now" reclaims space.

## Out of scope (YAGNI)

- Size-cap-based cleanup ("keep under X GB") — retention is purely time-based.
- Bulk multi-select delete in the UI.
- Re-downloading or re-creating expired audio.
- Migrating existing recordings' timestamps — `recordedAt` already exists on every
  `MeetingRecording`.
