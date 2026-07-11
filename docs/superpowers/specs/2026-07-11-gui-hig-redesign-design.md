# GUI refresh: align every surface with the Apple Human Interface Guidelines

**Date:** 2026-07-11
**Scope:** `Sources/MeetingAssistant/` view code only. No behavior, `AppState`,
or MeetingKit changes. All existing requirements (R11–R16b) stay satisfied.

## Problem

The UI works but reads as non-native in places: hard-coded point sizes instead
of semantic text styles, a hand-rolled details panel instead of the system
inspector, a custom red-gradient error banner, inconsistent Settings form
styles (one grouped tab, four plain padded tabs in a fixed frame that clips),
and ad-hoc quaternary boxes in onboarding. The goal is a refined, native macOS
look per the HIG — not a new layout.

## Constraints (from REQUIREMENTS.md)

- R11: translucent `NavigationSplitView` sidebar, SF Pro, single indigo accent,
  system neutrals, gentle depth. **Keep.**
- R12: large Record/Stop at the top of the sidebar. **Keep.**
- R13: serif reading view with **constrained measure** + Copy/Save/Reveal/
  Make-Again actions + Speakers rename. **Keep; actually enforce the measure.**
- R15/R16: menu-bar companion + Dock app. **Keep.**
- R16b: actions are visible buttons in the detail pane, not menus. **Keep.**

## Design

### 1. Typography — semantic styles only (all files)

Replace every `.font(.system(size: N))` with the closest HIG text style
(`.headline`, `.subheadline`, `.body`, `.callout`, `.caption`, `.caption2`),
keeping weight modifiers where they carry hierarchy. `SectionLabel` keeps its
small-caps look but derives from `.caption` instead of a fixed 11 pt.
Timestamps keep `.monospacedDigit()`.

### 2. Main window (`MainWindowView.swift`)

- **Speakers panel → native `.inspector`** (macOS 14 API): system material,
  system width behavior, toolbar toggle (`sidebar.right`). Shown by default
  when a meeting has speakers, so R16b's "visible" holds; the toggle only adds
  the standard way to reclaim space.
- **Transcript column → constrained measure**: cap the reading column at
  ~660 pt, centered in the remaining space (restores R13's stated design).
- **Error banner → native styling**: keep the transient bottom banner but
  restyle with `.regularMaterial` capsule/rounded rect, small red
  `exclamationmark.triangle.fill`, primary-colored text, standard shadow —
  no white-on-red gradient.
- **Sidebar rows**: semantic fonts; speaker count becomes a quiet
  `Text` + `person.2` badge as today but with `.caption` sizes.
- **Detail action row**: unchanged in content; consistent `.bordered` style,
  destructive Delete kept separated by a divider.

### 3. Menu-bar dropdown (`MenuBarView.swift`)

Same content and actions, clearer HIG hierarchy:
- Header (icon + name), then status, then the primary action as a full-width
  `.borderedProminent` regular-size button (Record / Stop & Transcribe).
- Secondary actions (`Record "<title>"`, Show Transcripts, Settings, Quit) as
  quiet standard buttons; consistent divider rhythm; footer row keeps
  Show Transcripts / Quit.

### 4. Settings (`SettingsView.swift`)

- All five tabs use `.formStyle(.grouped)` with `Section` headers — the modern
  System Settings look — instead of mixed plain forms.
- Drop the global fixed `460×360` frame; use a fixed width (~520) and let each
  tab size to content within a sensible height so nothing clips.
- Rows use `LabeledContent`/`Toggle`/`Picker` natively; caption footnotes stay
  as Section footers (`Text` in section content styled `.caption`/secondary).

### 5. Onboarding (`OnboardingView.swift`)

- Capability checklist and voice-enrollment card become `GroupBox`es (native
  card material) instead of `.quaternary.opacity(0.4)` rectangles.
- Semantic fonts; green/orange status colors unchanged; buttons unchanged.

### 6. Theme (`Theme.swift`)

Unchanged accent + speaker palette. `Space` scale kept. `SectionLabel`
switches to a semantic base font.

## Non-goals

- No new features, no behavior changes, no AppState/MeetingKit edits.
- No localization, no icon changes.

## Testing

View code is not unit-testable here (N8): verify with `swift build`,
`swift test` (must stay green — no MeetingKit changes expected), and a run of
`./Scripts/build-app.sh` to eyeball each surface. Existing pure-logic suites
are unaffected.
