# Actions as Visible Buttons (R16b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the detail-pane "More" menu (and the hidden context-menu Delete) with a single row of five clearly-labeled buttons: Copy · Save · Reveal · Make Again · Delete.

**Architecture:** All changes are in `Sources/MeetingAssistant/MainWindowView.swift`. `MeetingDetailView.actions` becomes an `HStack` of bordered, labeled buttons keeping each action's existing behavior + disabled logic. Delete reuses the existing window-level `confirmationDialog` via a new `requestDelete` closure passed into `MeetingDetailView` — no duplicate dialog, no new selection logic.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSWorkspace`).

**Spec:** `docs/superpowers/specs/2026-06-18-actions-as-buttons-design.md`

---

## File structure

- **Modify** `Sources/MeetingAssistant/MainWindowView.swift` — only file touched.
  - `MeetingDetailView`: add a `requestDelete: () -> Void` stored property.
  - `MainWindowView.detail`: pass `requestDelete:` at the `MeetingDetailView(...)` call site.
  - `MeetingDetailView.actions`: replace the `Copy` button + `"More"` `Menu` with the five-button row.

No new unit tests — pure SwiftUI composition wired to existing, already-tested actions (consistent with the inline-rename UI, R3d). Verified by `swift build` + running.

Reminder for all tasks: this repo uses **4-space indentation** (pinned by `.swift-format`). Stage only `Sources/MeetingAssistant/MainWindowView.swift` by explicit path; never `git add -A` or stage anything under `.claude/`. No AI/Claude mentions or Co-Authored-By trailers in commit messages.

---

## Task 1: Plumb a `requestDelete` closure into `MeetingDetailView`

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

This task only wires the closure (it compiles even before the Delete button uses it,
because the closure is stored and simply unused until Task 2).

- [ ] **Step 1: Add the stored property to `MeetingDetailView`**

Find the `MeetingDetailView` declaration:

```swift
private struct MeetingDetailView: View {
    @EnvironmentObject private var state: AppState
    let recording: MeetingRecording
    @State private var didCopy = false
```

Insert a `requestDelete` property right after `recording`:

```swift
private struct MeetingDetailView: View {
    @EnvironmentObject private var state: AppState
    let recording: MeetingRecording
    /// Ask the window to start its delete-confirmation flow for this recording.
    let requestDelete: () -> Void
    @State private var didCopy = false
```

- [ ] **Step 2: Pass the closure at the call site**

In `MainWindowView.detail`, find:

```swift
            MeetingDetailView(recording: rec)
```

Replace it with:

```swift
            MeetingDetailView(recording: rec, requestDelete: { pendingDelete = rec })
```

(`pendingDelete` is the existing `@State` on `MainWindowView`; the existing
window-level `confirmationDialog` already clears the selection and calls
`state.deleteRecording` when it is set.)

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: builds cleanly. (Ignore any SourceKit "cannot find type" diagnostics — only trust `swift build`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift
git commit -m "refactor: pass a requestDelete closure into MeetingDetailView"
```

---

## Task 2: Replace the actions Menu with a five-button row

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

- [ ] **Step 1: Replace the `actions` computed property**

Find the existing `actions` property in `MeetingDetailView`:

```swift
    private var actions: some View {
        let transcript = state.transcript(for: recording)
        return HStack(spacing: Theme.Space.s) {
            Button {
                copyToClipboard(transcript ?? "")
                didCopy = true
            } label: {
                Label(
                    didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(transcript == nil)
            .task(id: didCopy) {
                guard didCopy else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                didCopy = false
            }
            Menu {
                Button("Save to File…") {
                    saveToFile(transcript ?? "", suggestedName: recording.meeting.title)
                }
                .disabled(transcript == nil)
                Button("Show in Finder") {
                    let url = state.transcriptURL(for: recording)
                    NSWorkspace.shared.selectFile(
                        url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
                .disabled(transcript == nil)
                Divider()
                Button("Make Transcript Again") { Task { await state.reprocess(recording) } }
                    .disabled(!state.modelReady || !state.hasAudio(for: recording))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .labelStyle(.titleAndIcon)
    }
```

Replace the entire property with the five-button row (each action and disabled
condition is preserved exactly; the destructive Delete calls `requestDelete()`):

```swift
    private var actions: some View {
        let transcript = state.transcript(for: recording)
        return HStack(spacing: Theme.Space.s) {
            Button {
                copyToClipboard(transcript ?? "")
                didCopy = true
            } label: {
                Label(
                    didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(transcript == nil)
            .task(id: didCopy) {
                guard didCopy else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                didCopy = false
            }

            Button {
                saveToFile(transcript ?? "", suggestedName: recording.meeting.title)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(transcript == nil)

            Button {
                let url = state.transcriptURL(for: recording)
                NSWorkspace.shared.selectFile(
                    url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(transcript == nil)

            Button {
                Task { await state.reprocess(recording) }
            } label: {
                Label("Make Again", systemImage: "arrow.clockwise")
            }
            .disabled(!state.modelReady || !state.hasAudio(for: recording))
            .help("Make the transcript again")

            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
    }
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift
git commit -m "feat: surface transcript actions as visible buttons (R16b)"
```

---

## Task 3: Run verification

**Files:** none (verification only).

- [ ] **Step 1: Full build + test suite**

Run: `swift test`
Expected: all 155 tests pass (this change adds no tests and must not break any).

- [ ] **Step 2: Manual UI check**

Run: `./Scripts/build-app.sh --run`. Select a finished meeting and confirm:
- The detail pane shows five visible buttons in a row: **Copy · Save · Reveal ·
  Make Again · Delete** (Delete red). No "More" menu remains.
- **Copy** copies and flips to "Copied" for ~1.5s. **Save** opens a save panel.
  **Reveal** opens Finder at the transcript. **Make Again** re-runs transcription
  (and is disabled when the model isn't ready or audio was cleared).
- **Delete** shows the existing "Delete this meeting?" confirmation; confirming
  removes the recording and the detail pane returns to its empty state.
- For a meeting with no transcript yet, Copy / Save / Reveal are disabled.

- [ ] **Step 3: No commit** (verification only).

---

## Self-review notes

- **Spec coverage:** five visible labeled buttons replacing the Menu (Task 2) ✓;
  Delete as a visible button reusing the existing confirm/selection-clear flow via
  `requestDelete` (Tasks 1–2) ✓; each action + disabled condition preserved exactly,
  including the "Copied" feedback and the R26 audio-cleared disable (Task 2) ✓;
  sidebar right-click "Delete Meeting" mirror left untouched (out of scope) ✓.
- **Placeholder scan:** none — every step shows the exact code.
- **Type consistency:** `MeetingDetailView(recording:requestDelete:)` is used at the
  one call site (Task 1) and the `requestDelete()` call (Task 2) matches the stored
  `let requestDelete: () -> Void`. `pendingDelete`, `state.reprocess`,
  `state.hasAudio(for:)`, `state.modelReady`, `state.transcriptURL(for:)`,
  `copyToClipboard`, `saveToFile` are all existing symbols in the file.
- **No REQUIREMENTS change:** R16b already describes the desired end state (it was not
  marked *(planned)*); no status flip is needed.
