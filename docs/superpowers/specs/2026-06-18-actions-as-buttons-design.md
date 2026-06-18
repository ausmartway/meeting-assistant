# Actions as visible buttons (R16b) — design

**Requirement:** R16b (actions are visible buttons in the right pane, not menus)
**Date:** 2026-06-18
**Status:** Approved, ready for implementation plan

## Problem

Per R16b, actions a user performs on a selected recording should be **clearly
labeled buttons in the right-hand detail pane**, not tucked into menus. Today:

- The detail pane shows a **Copy** button plus a **"More" `Menu`** that hides
  *Save to File*, *Show in Finder*, and *Make Transcript Again*.
- **Delete** has no visible button at all — it is only reachable via a right-click
  **context menu** on the sidebar row.

Both hide primary actions behind menus, which R16b says to avoid.

## Decision (settled in brainstorming)

- Surface all five actions as **visible, labeled buttons in a single row** in the
  detail pane: **Copy · Save · Reveal · Make Again · Delete** (single labeled row;
  Delete last, destructive/red).
- Reuse the existing delete confirmation + selection-clearing flow rather than
  duplicating it.
- The sidebar right-click "Delete Meeting" stays as a convenience **mirror** (R16b
  permits a menu to also offer an action as long as a visible button is the primary
  path).

## Architecture

### 1. The action bar (`MeetingDetailView.actions` in `MainWindowView.swift`)

Replace the `Copy` button + `"More"` `Menu` with one `HStack` of five bordered,
labeled buttons (`.buttonStyle(.bordered)`, `.labelStyle(.titleAndIcon)`):

| Button | Label / SF Symbol | Action (unchanged) | Disabled when |
|---|---|---|---|
| Copy | "Copy" / "Copied" · `doc.on.doc` / `checkmark` | `copyToClipboard(transcript)` + 1.5s "Copied" reset | `transcript == nil` |
| Save | "Save" · `square.and.arrow.down` | `saveToFile(transcript, suggestedName: title)` | `transcript == nil` |
| Reveal | "Reveal" · `folder` | `NSWorkspace.selectFile(...)` | `transcript == nil` |
| Make Again | "Make Again" · `arrow.clockwise` | `Task { await state.reprocess(recording) }` | `!state.modelReady \|\| !state.hasAudio(for: recording)` |
| Delete | "Delete" · `trash` · `role: .destructive` | `requestDelete()` | — |

- The first four keep their **exact** current actions and disabled logic, including
  the "Copied" feedback (`.task(id: didCopy)`) and the R26 audio-cleared disable on
  Make Again.
- "Make Again" carries `.help("Make the transcript again")` since its label is short.
- No `Menu` remains in the detail pane.

### 2. Delete wiring (reuse, no duplication)

- `MeetingDetailView` gains a stored `let requestDelete: () -> Void`.
- At its single instantiation in `MainWindowView` (the detail builder), pass
  `requestDelete: { pendingDelete = rec }`.
- The Delete button calls `requestDelete()`.
- The **existing** window-level `confirmationDialog` (bound to `pendingDelete`)
  already clears the selection when the deleted id is selected and calls
  `state.deleteRecording`. No new confirmation dialog, no new selection logic.

## Error handling / edge cases

- **No transcript yet:** Copy/Save/Reveal are disabled (unchanged behavior).
- **Audio cleared (R26):** Make Again is disabled; the detail header already shows
  the "Audio cleared to save space" note — no new messaging needed.
- **Deleting the selected meeting:** handled by the existing dialog
  (`if selection == recording.meeting.id { selection = nil }`), returning the detail
  pane to its empty state.

## Testing

No new unit tests — this is pure SwiftUI view composition wired to existing,
already-tested actions (consistent with how the inline-rename UI, R3d, was handled).
Verified by `swift build` + running:

- All five actions are visible, labeled buttons in the detail pane; Save / Reveal /
  Make Again are no longer hidden in a menu.
- Delete shows the existing confirmation, deletes on confirm, and the selection
  resets to the empty state.
- Disabled states intact (no transcript → Copy/Save/Reveal disabled; audio cleared →
  Make Again disabled).

## Out of scope (YAGNI)

- Removing the sidebar right-click "Delete Meeting" mirror (kept as a convenience).
- Restyling other parts of the detail pane (speakers section, header, progress row).
- Any change to the underlying actions themselves (copy/save/reveal/reprocess/delete
  logic is unchanged).
