# Stop in-flight transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Stop** control that cancels the transcript currently being made, leaving queued transcripts running and the stopped meeting re-transcribable.

**Architecture:** Each queue item is processed in its own child `Task` that `AppState` holds; Stop cancels just that task and the drain loop advances to the next item. Cancellation is cooperative — `MeetingProcessor.process` checks `Task.isCancelled` at step boundaries, so a cancel stops at the next checkpoint and nothing partial is written.

**Tech Stack:** Swift structured concurrency (`Task` / `Task.checkCancellation()`), SwiftUI, swift-testing.

---

## File Structure

- **Modify** `Sources/MeetingKit/MeetingProcessor.swift` — add `try Task.checkCancellation()` after transcribe and after diarize.
- **Create** `Tests/MeetingKitTests/MeetingProcessorCancellationTests.swift` — proves a cancelled process throws `CancellationError` and writes no transcript.
- **Modify** `Sources/MeetingKit/Transcriber.swift` — add a `try Task.checkCancellation()` at the start of `WhisperKitTranscriber.transcribe` (best-effort earlier stop).
- **Modify** `Sources/MeetingAssistant/AppState.swift` — per-item task handle, `stopCurrentTranscription()`, silent `CancellationError` handling, `isTranscribing`.
- **Modify** `Sources/MeetingAssistant/MenuBarView.swift` — Stop button by the progress block.
- **Modify** `Sources/MeetingAssistant/MainWindowView.swift` — Stop button in the progress row.

---

### Task 1: MeetingProcessor cancellation checkpoints

**Files:**
- Modify: `Sources/MeetingKit/MeetingProcessor.swift`
- Test: `Tests/MeetingKitTests/MeetingProcessorCancellationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/MeetingProcessorCancellationTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingProcessor cancellation")
struct MeetingProcessorCancellationTests {

    // A transcriber that returns promptly and ignores cancellation — simulating an
    // engine that doesn't honor cooperative cancellation. This forces the test to
    // exercise MeetingProcessor's OWN `Task.checkCancellation()` guard after the
    // transcribe step, rather than the transcriber throwing for us.
    private struct IgnoresCancellationTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?) async throws -> [TranscriptSegment] {
            channel == .microphone
                ? [TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone)]
                : []
        }
    }

    private func makeRecording() throws -> (MeetingStore, MeetingRecording) {
        let store = try MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-cancel-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: [])
        )
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        return (store, recording)
    }

    @Test("a cancelled process throws CancellationError and writes no transcript")
    func cancelStopsBeforeSave() async throws {
        let (store, recording) = try makeRecording()
        let processor = MeetingProcessor(
            store: store,
            transcriber: IgnoresCancellationTranscriber(),
            diarizer: StubDiarizer(),
            knownSpeakers: []
        )

        // Cancel immediately: transcribe still returns (it ignores cancellation),
        // but the checkpoint after it must throw before anything is persisted.
        let task = Task { try await processor.process(recording) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(store.transcript(for: recording.meeting.id) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "MeetingProcessor cancellation"`
Expected: FAIL — without the checkpoint, `process` runs to completion and saves a transcript, so it does NOT throw `CancellationError` (and `store.transcript(...)` is non-nil).

- [ ] **Step 3: Add the cancellation checkpoints**

In `Sources/MeetingKit/MeetingProcessor.swift`, after the transcribe step (the line `let allSegments = try await (micSegments + systemSegments).sorted { $0.start < $1.start }`, ~line 52-53), insert:

```swift

        // The user may have stopped this transcript while the (cancellation-
        // cooperative) transcribe step ran. Bail before the expensive diarize/fuse/
        // save so nothing partial is written — the recording stays re-transcribable.
        try Task.checkCancellation()
```

Then, after the diarize `do { … } catch { … }` block (the one ending ~line 66, just before the `// 2c. Fuse speaker labels` comment), insert:

```swift

        // Second checkpoint: stop before fusing/formatting/saving if cancelled
        // during diarization.
        try Task.checkCancellation()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter "MeetingProcessor cancellation"`
Expected: PASS — process throws `CancellationError`, no transcript saved.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `swift test`
Expected: all pass (the existing `MeetingProcessor diarization wiring` tests still pass — they never cancel, so the checkpoints are no-ops for them).

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/MeetingProcessor.swift Tests/MeetingKitTests/MeetingProcessorCancellationTests.swift
git commit -m "feat: make MeetingProcessor honor cancellation at step boundaries"
```

---

### Task 2: WhisperKitTranscriber early cancellation check

**Files:**
- Modify: `Sources/MeetingKit/Transcriber.swift`

No unit test: this code is inside `#if canImport(WhisperKit)` and the app target doesn't link WhisperKit, so it's only compiled in the real build — verified by building under full Xcode. It's a best-effort earlier stop; the guaranteed stop points are Task 1's checkpoints.

- [ ] **Step 1: Add the check**

In `Sources/MeetingKit/Transcriber.swift`, inside `WhisperKitTranscriber.transcribe(audioFile:channel:progress:)`, immediately after `let pipe = try await pipeline(progress: progress)` (~line 152), insert:

```swift
        // If the user already stopped this transcript, don't start a new channel.
        // (WhisperKit's own VAD loop is cooperatively cancellable too, so a stop
        // mid-channel unwinds at the next chunk.)
        try Task.checkCancellation()
```

- [ ] **Step 2: Build (full Xcode compiles the WhisperKit path)**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingKit/Transcriber.swift
git commit -m "feat: check cancellation before starting a WhisperKit channel"
```

---

### Task 3: AppState — per-item task, stop method, silent cancel handling

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift`

- [ ] **Step 1: Add the per-item task property**

Next to `private var drainTask: Task<Void, Never>?` (~line 75), add:

```swift
    /// The task transcribing the CURRENT queue item, held so the user can stop just
    /// that item. Cancelling it makes the drain loop advance to the next queued
    /// meeting; queued items are untouched.
    private var currentItemTask: Task<Void, Never>?
```

- [ ] **Step 2: Add the `isTranscribing` computed property**

Next to `var isRecording: Bool { recording != nil }` (~line 42), add:

```swift
    /// True while a transcript is being made (drives the Stop control).
    var isTranscribing: Bool { processing.current != nil }
```

- [ ] **Step 3: Run each queue item in a cancellable child task**

Replace `drainProcessingQueue()` (currently ~lines 336-347):

```swift
    private func drainProcessingQueue() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while let meeting = processing.startNext() {
                await process(meeting)
                processing.finishCurrent()
                progressFraction = nil
                progressPhase = nil
            }
            drainTask = nil
        }
    }
```

with:

```swift
    private func drainProcessingQueue() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while let meeting = processing.startNext() {
                // Process each item in its own child task so the user can stop just
                // this one (cancelling it) without tearing down the whole queue.
                let item = Task { @MainActor in await self.process(meeting) }
                currentItemTask = item
                await item.value
                currentItemTask = nil
                processing.finishCurrent()
                progressFraction = nil
                progressPhase = nil
            }
            drainTask = nil
        }
    }

    /// Stop the transcript currently being made. Queued meetings keep transcribing
    /// — the drain loop advances to the next. The stopped meeting keeps its audio
    /// and can be transcribed again later. Silent: no notification, no error banner.
    func stopCurrentTranscription() {
        currentItemTask?.cancel()
    }
```

- [ ] **Step 4: Handle a user stop silently in `process(_:)`**

In `process(_:)` (~lines 370-375), replace:

```swift
        do {
            _ = try await processor.process(recording, progress: progress)
            postNotification(title: "Transcript ready", body: "The transcript for “\(meeting.title)” is ready.")
        } catch {
            lastError = userFacingMessage(for: .transcribing, error: error)
        }
```

with:

```swift
        do {
            _ = try await processor.process(recording, progress: progress)
            postNotification(title: "Transcript ready", body: "The transcript for “\(meeting.title)” is ready.")
        } catch is CancellationError {
            // User stopped this transcript: silent — no error banner, no "ready"
            // notification. The recording stays on disk with no transcript and can
            // be re-run later via "Make Transcript Again".
        } catch {
            lastError = userFacingMessage(for: .transcribing, error: error)
        }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 6: Run tests**

Run: `swift test`
Expected: all pass (no behavior change for the non-cancel path).

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: let AppState stop the current transcript and advance the queue"
```

---

### Task 4: Stop button in the UI

**Files:**
- Modify: `Sources/MeetingAssistant/MenuBarView.swift`
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

- [ ] **Step 1: Menu-bar Stop button**

In `Sources/MeetingAssistant/MenuBarView.swift`, inside the `if state.processing.current != nil { … }` block (~lines 134-151), add a Stop button as the last element before the block's closing brace — after the `if state.processing.pendingCount > 0 { … }` sub-block:

```swift
                Button(role: .destructive) {
                    state.stopCurrentTranscription()
                } label: {
                    Label("Stop Transcript", systemImage: "stop.circle")
                }
                .controlSize(.small)
```

- [ ] **Step 2: Main-window Stop button**

In `Sources/MeetingAssistant/MainWindowView.swift`, replace `progressRow` (~lines 339-353):

```swift
    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = state.progressFraction {
                ProgressView(value: fraction) { Text(state.progressPhase ?? "Transcribing…").font(.caption) }
                Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.progressPhase ?? "Transcribing…").font(.caption)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

with:

```swift
    private var progressRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = state.progressFraction {
                    ProgressView(value: fraction) { Text(state.progressPhase ?? "Transcribing…").font(.caption) }
                    Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.progressPhase ?? "Transcribing…").font(.caption)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                state.stopCurrentTranscription()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingAssistant/MenuBarView.swift Sources/MeetingAssistant/MainWindowView.swift
git commit -m "feat: add Stop control to transcription progress in menu bar and window"
```

---

### Task 5: Manual verification (run the app)

**Files:** none — behavioral verification per the repo's "integrations verified by running" policy.

- [ ] **Step 1: Build and run**

Run: `./Scripts/build-app.sh --run`

- [ ] **Step 2: Start a transcript and stop it**

Record (or "Make Transcript Again" on) a longer meeting so transcription is in flight. While "Making transcript…/Transcribing…" shows, click **Stop Transcript** (menu bar) or **Stop** (main window).
Expected: progress disappears within a few seconds (at the next checkpoint), no error banner, no "Transcript ready" notification. The meeting remains in the list with **Make Transcript Again** available.

- [ ] **Step 3: Verify the queue keeps going**

With two meetings queued, stop the first while it transcribes.
Expected: the second meeting begins transcribing on its own (the drain loop advanced); only the stopped one is left without a transcript.

- [ ] **Step 4: Re-transcribe the stopped meeting**

Click **Make Transcript Again** on the stopped meeting.
Expected: it transcribes to completion normally.

---

## Notes

- **Out of scope (per spec):** removing individual queued items / clearing the queue; discarding the recording on stop; any "stopped" notification/toast; resuming a partial transcript.
- **Cancellation latency:** a stop takes effect at the next checkpoint — after the current WhisperKit channel/chunk — not necessarily instantly. This is expected and documented; the two `Task.checkCancellation()` points guarantee no partial transcript is written.
- **REQUIREMENTS.md:** add a brief requirement near R2/R3 (e.g. **R3b — Stop transcription.** The user can stop the in-flight transcript; queued meetings continue and the stopped meeting stays re-transcribable). Do this as part of Task 3's commit, or a small `docs:` commit.
