# Stop in-flight transcription

**Date:** 2026-06-17
**Status:** Approved, pending implementation

## Problem

Once a meeting's transcription starts, there is no way to stop it. A long meeting
can occupy the serial transcription queue for minutes with no escape; the user
must wait it out. We want a **Stop** control that cancels the transcript currently
being made.

## Decisions

- **Scope:** Stop cancels only the *current* in-flight transcript. Meetings queued
  behind it keep transcribing — the drain loop advances to the next item.
- **After stop:** the meeting stays saved as a re-transcribable recording (audio +
  metadata, no transcript). Nothing is deleted; the existing "Make transcript
  again" (`reprocess`) re-runs it later.
- **Placement:** a Stop control next to the "Making transcript…" progress in *both*
  the menu-bar popover and the main-window progress row.
- **Silent:** stopping shows **no** notification and **no** error banner.

## Approach

The drain loop currently runs every queued item inside a single `drainTask`.
Cancelling that whole task would also kill the queue, which contradicts "keep
queue". Instead, **each item gets its own child Task** that `AppState` holds a
handle to; Stop cancels only that handle and the loop advances to the next item.

Cancellation is **cooperative**: `MeetingProcessor.process` checks
`Task.isCancelled` at step boundaries, so work stops at the next checkpoint and no
partial transcript is written. (A progress-callback flag was rejected — it would
not actually interrupt the in-actor WhisperKit call.)

## Components

### `AppState` (`Sources/MeetingAssistant/AppState.swift`)

- New `private var currentItemTask: Task<Void, Never>?` — the task processing the
  current item.
- `drainProcessingQueue()` loop: for each item, `currentItemTask = Task { await
  process(meeting) }`, then `await currentItemTask?.value`, then `finishCurrent()`
  and clear progress, and continue. Queue/FIFO semantics unchanged; idempotent
  guard on `drainTask` unchanged.
- New `func stopCurrentTranscription()` → `currentItemTask?.cancel()`. It does
  **not** mutate the queue, so pending items are untouched.
- `process(_:)`: add `catch is CancellationError { return }` *before* the generic
  error catch — a user stop is not an error: no `lastError`, no "Transcript ready"
  notification. The generic catch (real failures) is unchanged.
- New computed `var isTranscribing: Bool { processing.current != nil }` to drive
  the button's visibility/enabled state.

### `MeetingProcessor.process` (`Sources/MeetingKit/MeetingProcessor.swift`)

- Add `try Task.checkCancellation()` after the transcribe step and after diarize,
  before the synchronous fuse/format/save. The transcript and speaker map are
  written only after fusion, so a cancel before that point leaves nothing partial
  on disk.

### `WhisperKitTranscriber` (`Sources/MeetingKit/Transcriber.swift`)

- If the transcribe path has a per-chunk / per-worker loop, add a
  `try Task.checkCancellation()` inside it so a long meeting stops mid-file.
  Otherwise the cancel takes effect at the step boundary after the current
  `transcribe()` returns. Instantaneity depends on WhisperKit honoring cooperative
  cancellation — documented as a known caveat, not a correctness requirement.

### UI

- A **Stop** control labelled "Stop transcript" (distinct from recording's "Stop &
  Transcribe"), shown when `isTranscribing`, calling
  `state.stopCurrentTranscription()`:
  - `MenuBarView.swift` — next to the "Making transcript…" progress block.
  - `MainWindowView.swift` — in the progress row.

## State left behind by a stop

- **Kept:** the meeting's audio files (`mic.wav`, `system.wav`) and
  `recording.json`.
- **Absent:** `transcript.md` and `speakers.json` (never written because cancel
  precedes the save step).
- The meeting appears in the list with the existing "Make transcript again"
  action. Nothing is lost.

## Testing

- **Unit test (new), swift-testing:** a cooperative `StubTranscriber` that awaits
  cancellation; wrap `MeetingProcessor.process` in a Task, cancel it, and assert it
  throws `CancellationError` and writes **no** transcript. Pins the cancellation
  boundary — the one piece of testable logic.
- UI wiring and the live WhisperKit cancel are verified by running the app, per the
  repo's "integrations verified by running" convention.

## Out of scope

- Removing individual queued items / clearing the whole queue.
- Discarding the recording on stop.
- A "Transcription stopped" notification or toast.
- Resuming a stopped transcript mid-way (a re-run starts fresh).
