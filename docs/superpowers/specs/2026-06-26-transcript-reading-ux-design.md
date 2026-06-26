# Transcript reading-view UX overhaul — design

**Date:** 2026-06-26
**Status:** Approved (implements the UX review of the transcript screen)
**Scope:** `Sources/MeetingAssistant/MainWindowView.swift`, `Theme.swift`, and two
new pure helpers in `MeetingKit`. No change to capture/processing.

## Problem (from the UX review)

The transcript reading screen presents the stored Markdown almost raw:
- `MarkdownText` uses `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)`,
  so the `# title`, the ISO date line, and the `_note_` render as literal/odd text,
  and the single-`\n` turn separators collapse into a **wall of text**.
- `MarkdownText` forces `.frame(maxWidth: .infinity)`, defeating the caller's 720
  cap — the body runs edge-to-edge across a very wide window (unreadable measure).
- Speaker turns aren't visually separable; the "Speakers" editor shows a redundant
  chip **and** a field; Delete isn't visually destructive; the "Loading model…"
  pill floats over content; the audio-cleared notice reads as easily-missed body
  text; sidebar rows are hard to tell apart and the badge meaning is unclear.

## Decisions (resolving the review's open choices)

- **Reading layout:** a single centered reading column, `maxWidth ≈ 680`, generous
  side gutters. **No card surface** (stay restrained/native, like Notes); "gentle
  depth" comes from spacing, not a panel. A small **footer** (word count · speaker
  count) closes the bottom void.
- **Per-turn rendering:** one block per turn — speaker name (SF Pro, semibold,
  per-speaker color; indigo reserved for "Me") + timestamp (secondary, caption,
  monospaced digits) on a header line, serif speech beneath, ~12pt between turns.
- **Timestamps:** keep the existing **wall-clock `HH:mm:ss`** already stored
  (meaningful real time-of-day); just style them quietly. (The review's "raw ISO"
  concern was the document *date header*, which we drop from the body.)
- **Parsing:** add a pure, tested `TranscriptParser` (MeetingKit) that turns the
  stored document string into `{title?, note?, turns:[Turn]}` so the view renders
  structure, not raw markup. Export/Copy/Save keep using the full document string.
- **Speakers editor:** one editable field per speaker (drop the redundant chip),
  Return-to-commit, a Save affordance that appears only when the draft is dirty, and
  a one-line helper. Keep it visible (don't hide behind a disclosure).
- **Auto-title for the sidebar (display only):** when a recording's title is the
  generic provider default (e.g. "Microsoft Teams meeting"), show a distinguishing
  display title derived from its speakers/first words via a pure tested helper —
  **without** changing the stored title (rename still works).

## Components

### 1. `TranscriptParser` — new pure module (MeetingKit, tested)

```swift
public enum TranscriptParser {
    public struct Turn: Equatable, Sendable {
        public let time: String     // e.g. "14:53:02" (may be empty)
        public let speaker: String  // e.g. "Me", "Cameron Huysman", "Speaker 2"
        public let text: String
    }
    public struct Parsed: Equatable, Sendable {
        public let title: String?
        public let note: String?
        public let turns: [Turn]
    }
    public static func parse(_ document: String) -> Parsed
}
```

Parses the canonical format from `TranscriptFormatter`:
- a leading `# <title>` line → `title` (dropped from body),
- the next ISO-date line → discarded,
- an italic `_<note>_` line → `note`,
- each turn line `**[<time>] <speaker>:** <text>` → a `Turn`. A line that doesn't
  match the turn pattern but follows a turn is appended to that turn's text (defends
  against embedded newlines). Lines that match nothing are ignored.

### 2. `MeetingDisplayTitle` — new pure module (MeetingKit, tested)

```swift
public enum MeetingDisplayTitle {
    /// A distinguishing sidebar label. Returns `title` unchanged unless it's a
    /// generic provider default, in which case it appends a hint built from the
    /// most prominent non-"Me" speaker (else returns the title unchanged).
    public static func sidebarTitle(
        title: String, providerDefault: String?, speakers: [String], localUserName: String
    ) -> String
}
```

Generic detection: `title == providerDefault`. Hint: the first speaker that isn't
`localUserName` and isn't an anonymous `Speaker N`; if none, the title is left as-is
(the date subtitle already differentiates). Pure + tested.

### 3. Reading view — replace `MarkdownText` with `TranscriptReadingView`

- Renders `TranscriptParser.parse(...)`:
  - optional `note` as a small secondary caption at the top,
  - `ForEach(turns)` → `TurnView`: header line (speaker label in `speakerColor`,
    monospaced secondary time) + serif body (`Theme.reading`, `lineSpacing 6`),
    `~12pt` vertical gap between turns, `textSelection(.enabled)`.
- Whole column constrained: `.frame(maxWidth: 680, alignment: .leading)` then
  centered with `.frame(maxWidth: .infinity)` on the *container* (not the text), so
  the cap actually holds. Horizontal gutter padding.
- Footer: `"<n> words · <m> speakers"`, caption secondary, below the turns.
- `speakerColor(for:)`: `"Me"`/localUserName → `Theme.accent`; otherwise a stable
  hash into a small palette of muted, dark-mode-safe colors. Add to `Theme`.

### 4. Speakers editor — `SpeakerRenameRow` cleanup

- Drop the `SpeakerChip`; the editable `TextField` (prefilled with the label) is the
  single source of truth, with the label shown as its placeholder/value.
- Save button (`checkmark.circle.fill`, accent) appears only when `canSave`
  (non-empty & changed); Return also commits. Add a row helper the first time:
  section subtitle "Renaming teaches this person's voice for future meetings."
- "Me"/local rows: indicate which is you (small "you" caption), still renameable.

### 5. Actions row

- Group safe actions (Copy, Save, Reveal, Make Again) at the leading edge, then a
  `Spacer()`, then **Delete** pushed to the trailing edge with `.tint(.red)` /
  red foreground (confirmation dialog already exists).
- Disabled "Make Again": add `.help("Audio was cleared to save space — re-transcribing isn't available.")` so the disabled state is explained.

### 6. State & feedback

- **Model pill:** stop floating it over content. Move the model-preparing indicator
  into the toolbar (alongside `recordControl`, top-trailing) as a small
  `ProgressView` + "Preparing model…" label; remove the centered `.overlay(.top)`.
- **Audio-cleared notice:** render as a subtle info callout — rounded
  `.quaternary`-fill capsule/box with an `info.circle` glyph and secondary text —
  instead of plain caption, so it registers as status. Same wording.

### 7. Sidebar

- **Badge:** replace the bare number with `Image(systemName: "person.2")` + count,
  `.secondary`, with `.help("<n> speakers")`. (Drop entirely when count is 0.)
- **Titles:** use `MeetingDisplayTitle.sidebarTitle(...)` for the row title so
  identical provider-default meetings become distinguishable.
- **Storage footer:** de-emphasize (smaller, `.secondary`, leading-aligned) and make
  it a `Button`/tappable that opens Settings → Storage.

### 8. Polish

- Dark-mode contrast: ensure secondary/tertiary text used here clears AA; prefer
  `.secondary` over `.tertiary` for the date subtitle and notice.
- Disabled affordances never rely on color alone (tooltips added above).

## Testing

Pure, swift-testing:
- `TranscriptParser` — title/ISO/note stripping; turn parsing (`[time] speaker: text`);
  multi-line turn continuation; empty/garbage input → empty turns; a body-only
  string (no header) still parses turns.
- `MeetingDisplayTitle` — generic title + named remote speaker → appended hint;
  non-generic title → unchanged; only-"Me"/anonymous speakers → unchanged; empty
  speakers → unchanged.

View changes (reading layout, editor, actions, banners, sidebar, footer) are
verified by **building and running** the app and inspecting a screenshot — SwiftUI
views aren't unit-tested in this project.

## Build order

1. `TranscriptParser` (+ tests).
2. `MeetingDisplayTitle` (+ tests).
3. `Theme`: `speakerColor(for:localUserName:)` palette helper.
4. Reading view: `TranscriptReadingView` + `TurnView`, replace `MarkdownText`,
   constrained measure + footer.
5. Speakers editor cleanup (`SpeakerRenameRow`, helper line).
6. Actions row (Delete separation/red + Make Again tooltip).
7. Model pill → toolbar; audio-cleared notice → info callout.
8. Sidebar: badge icon, display title, storage footer button.
9. Build + run + screenshot verification; dark-mode contrast pass.
