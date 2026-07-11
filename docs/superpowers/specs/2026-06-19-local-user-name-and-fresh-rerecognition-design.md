# Local-user name + fresh re-recognition — design

**Date:** 2026-06-19
**Status:** Approved, ready for implementation plan

## Problem

1. The local user is labelled the generic **"Me"** in transcripts and the UI. The owner
   wants their real name (defaulting to the macOS account name, editable).
2. On **re-transcribe**, the previous transcription's speaker identifications persist
   (the per-meeting speaker map), so a stale/wrong label (e.g. a bogus "Jane Doe")
   survives. Re-transcribing should re-recognize speakers from scratch and drop the
   prior identifications.

## Decisions (settled in brainstorming)

- Local-user name **defaults to the macOS account full name** (`NSFullUserName()`),
  **editable in Settings**, falling back to "Me" when blank.
- The local user stays the **`isMe`** identity in the speaker library; only its *name*
  changes from "Me" to the chosen name. Names are emitted **at the source** (fusion +
  recognition), so new transcripts contain the real name directly.
- An existing "Me" enrollment is **migrated** (renamed) — no re-enrollment.
- **Re-transcribe deletes the per-meeting speaker map first**; the **global** speaker
  library (cross-meeting voiceprints, R9) is untouched.
- Past transcripts are left as recorded.

## Architecture

### 1. Name resolution (pure) + setting

```swift
// MeetingKit, pure + unit-tested.
public enum LocalUserName {
    /// Trimmed `override` if non-empty; else trimmed `accountName` if non-empty;
    /// else "Me".
    public static func resolve(override: String, accountName: String) -> String
}
```

`AppSettings` (app target):
- `@Published var localUserName: String` persisted in UserDefaults under
  `"localUserName"`.
- Default at first launch: `LocalUserName.resolve(override: "", accountName: NSFullUserName())`.
- A computed/stored value the rest of the app reads for the local user's display name.

### 2. Apply the name end-to-end

- **Speaker library** (`SpeakerLibrary`): add
  `setLocalUserName(_ name: String)` — if an `isMe` entry exists and its name differs,
  rename it to `name` (preserving the voiceprint + `isMe`); no-op if already correct or
  if not enrolled. Idempotent. Called at launch and whenever `localUserName` changes.
  This migrates an existing "Me" entry.
- **Enrollment** (`AppState.enroll`): upsert under `localUserName` with `isMe: true`
  (instead of the literal "Me").
- **Fusion**: `MeetingProcessor` calls `SpeakerFuser.fuse(..., micLabel: localUserName)`
  so non-diarized mic segments carry the name. (The `micLabel` parameter already exists.)
- **Diarized path**: `SpeakerRecognizer` resolves the enrolled cluster to the library
  entry's name — now `localUserName` — so it is consistent with no further change.
- **UI "this is me" highlight**: the `SpeakerChip(isMe:)` / speakers-section checks
  switch from `label == "Me"` to `label == settings.localUserName`.
- **Settings (Speakers tab)**: a text field bound to `localUserName`; on commit it
  persists, re-syncs the library (`setLocalUserName`), and applies to future
  transcriptions. A blank field falls back to the resolved default.
- `MeetingProcessor` takes the local-user label as a parameter (passed by `AppState`
  from `settings.localUserName`) so MeetingKit stays free of app-settings/`AppKit`.

### 3. Fresh re-recognition on re-transcribe

- **`MeetingStore.deleteSpeakerMap(meetingID:)`** — remove the per-meeting
  `speakers.json` (idempotent; no-op if absent).
- `MeetingProcessor.process` calls it **at the start**, before diarize/resolve/fuse, so
  every (re-)transcription begins with no prior per-meeting identifications:
  - First transcription: no map yet → no-op.
  - Re-transcription: clears the stale map (drops e.g. "Jane Doe"), then recomputes.
- The fresh run re-recognizes against the **global** library (diarization on) or labels
  mic = `localUserName` / remote = on-screen name or "Speaker" (diarization off).
- The global `SpeakerLibrary` is never cleared here.

## Error handling / edge cases

- **Not enrolled:** `setLocalUserName` is a no-op; fusion still uses `localUserName` for
  the mic label, so the name shows even without enrollment.
- **Blank name in Settings:** resolver falls back to account name, then "Me".
- **Re-transcribe with diarization off:** no new map is written; the delete ensures no
  stale map lingers, so the UI shows mic = name + remote labels only.
- **Name edited after enrollment:** `setLocalUserName` renames the isMe entry to keep
  the voiceprint tied to the displayed name; past transcripts are unchanged.

## Testing

Pure / unit-tested (swift-testing):
- `LocalUserName.resolve`: override wins; blank override → account name; both blank →
  "Me"; whitespace trimmed.
- `SpeakerLibrary.setLocalUserName`: renames the isMe entry, preserves embedding + isMe;
  no-op when already correct; no-op when not enrolled; leaves non-isMe speakers alone.
- `SpeakerFuser`: mic segments carry the supplied `micLabel`.
- `MeetingStore.deleteSpeakerMap`: removes an existing map; no-op when absent; leaves the
  rest of the bundle (audio, transcript, recording.json) intact.
- `MeetingProcessor`: after processing a meeting that had a pre-existing speaker map, the
  old map is gone / replaced (re-recognition started fresh).

Verified by running (N8): transcripts and the UI show the account name (e.g.
"Yulei Liu") instead of "Me"; editing the name in Settings updates future transcripts
and the "me" highlight; re-transcribing the mislabeled meeting drops "Jane Doe".

## Out of scope (YAGNI)

- Rewriting/relabelling past transcripts when the name changes.
- iCloud / Apple-ID display-name lookup (unavailable without entitlements).
- Clearing or migrating the global speaker library.
