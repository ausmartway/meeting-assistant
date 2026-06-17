# Requirements

The product requirements for Meeting Assistant — both **explicit** (features the
owner asked for) and **implicit** (constraints and quality bars that are expected
even though never spelled out as a ticket). This is the source of truth for *what*
the app must do and *how it must feel*; `CLAUDE.md` covers *how the code is
organized*.

> Audience note: the owner is a Sales Engineer (DevOps). The app — and any code or
> UI in it — may be seen by customers, so everything is held to a clean,
> production-quality, "demo-ready" bar even in internal corners.

---

## 1. What the app is

A native **macOS menu-bar + Dock app** (Swift + SwiftUI, deployment target
**macOS 14**) that watches the calendar, prompts to capture Zoom/Meet/Teams
meetings, and produces a **speaker-labeled transcript**, transcribed **locally** on Apple
Silicon. It only transcribes — summarization was intentionally removed.

---

## 2. Explicit functional requirements

### Capture & recording
- **R1 — Prompt to record.** When a calendar meeting starts and the user joins from
  the Zoom / Teams / Google Meet app, the app posts an actionable "Start recording?"
  notification (once per meeting); recording begins only when the user taps its
  **Start Recording** button. Recording never starts on its own. Manual "Record a
  meeting now" is always available.
- **R2 — Record while transcribing.** The user can start a new recording while
  earlier meetings are still being transcribed. Recording is independent of
  transcription; finished meetings queue and transcribe serially in the background.
- **R3 — Immediate meeting entry.** The moment "Record" is pressed, a meeting entry
  appears in the list (shown live; it is **not** persisted to disk until the
  recording is stopped and finalized).
- **R3b — Stop transcription.** The user can stop the in-flight transcript from the
  menu bar or the main window. Stopping is silent (no notification), leaves any
  queued meetings transcribing, and keeps the stopped meeting re-transcribable
  ("Make Transcript Again") — nothing partial is written.

### Transcription quality
- **R4 — Readable transcripts.** Transcripts must be clean. Whisper artifacts —
  especially repetition-loop garbage (walls of one repeated character/word such as
  `$$$$…` or `LAUGHTER LAUGHTER…`) — must be filtered out, alongside the existing
  silence/stock-phrase hallucinations.
- **R5 — Multilingual.** Transcription auto-detects language; English **and**
  Mandarin are first-class (multilingual Whisper models, no `.en` variants).

### Speakers
- **R6 — In-room speaker separation.** When the user is physically in a room with
  other people (all arriving on the single mic channel), the app separates the
  distinct in-room voices instead of labeling everyone "Me".
- **R7 — "Me" via enrollment.** The user enrolls their own voice once by **reading
  an on-screen script** during initial setup (and re-doable in Settings); their
  enrolled voice is labeled "Me", others become "Speaker 2", "Speaker 3", ….
- **R8 — Name anonymous speakers, remembered locally.** The user can rename an
  anonymous speaker (e.g. "Speaker 2" → "Sam") from the transcript. The name is
  remembered locally.
- **R9 — Cross-meeting recognition.** Naming a speaker stores that voice's print in
  a **local speaker library**, so the same person is auto-recognized by name in
  future meetings. "Me" is just the enrolled member of that library.
- **R10 — Conservative matching.** Only **confident** voice matches are auto-named;
  weak matches stay anonymous rather than risk the wrong name.

### Interface (elegant, native macOS Dock app)
- **R11 — Elegant, easy-to-use, native.** The GUI is a refined, native-macOS Dock
  app: translucent `NavigationSplitView` sidebar, SF Pro typography, a single
  restrained indigo accent (from the app icon), system semantic neutrals (light &
  dark), gentle depth — not a bold/aggressive style.
- **R12 — Prominent Record action.** A large, prominent Record/Stop button at the
  **top of the sidebar** (not a small toolbar control).
- **R13 — Transcript reading view.** Speaker-labeled transcript shown in a
  comfortable reading layout (serif body, constrained measure), with Copy / Export
  (Save / Reveal) / Make-again actions and a Speakers section for renaming.
- **R14 — Distinctive app icon.** A custom icon (microphone + waveform on a
  blue→indigo squircle), not the generic default.
- **R15 — Discoverable setup.** Voice enrollment and settings are reachable from
  the menu bar (no hunting); Settings toggles must visibly take effect.
- **R16 — Dock app.** Ships as a Dock-first app (Dock icon on by default) while
  keeping the menu-bar item as a lightweight status + quick-record companion.

### Distribution
- **R17 — Homebrew.** Installable via a Homebrew cask
  (`brew install --cask meeting-assistant` after tapping the repo). The cask’s
  version + sha256 stay current automatically on each tagged release.
- **R18 — Signed releases / DMG.** Distributed as a DMG via GitHub Releases on
  `v*` tags, signed with the stable self-signed certificate.

---

## 3. Implicit / non-functional requirements

- **N1 — Local-first & private.** Audio and transcripts **never leave the
  device**. All transcription and speaker work runs on-device. (This is
  load-bearing — do not add cloud dependencies; it is why live cloud transcription
  was rejected, see §4.)
- **N2 — Cheap live capture, heavy post-processing.** The component that runs
  *during* a meeting stays lightweight; transcription and speaker fusion run
  **after** the meeting. New live-path features must respect this (R2's recording
  is light; transcription stays post-meeting).
- **N3 — Best-effort, never fatal.** Optional/fragile features degrade gracefully
  rather than break the meeting: diarization or recognition failure falls back to
  blanket "Me"; a failed step never loses the recording or the authoritative
  transcript.
- **N4 — No data loss / no premature persistence.** Don't persist incomplete
  artifacts (e.g. a recording isn't saved until its audio files are finalized);
  renaming must never silently corrupt enrollment or overwrite another known
  speaker's voiceprint.
- **N5 — No regressions.** Changes preserve existing behavior unless explicitly
  changing it; the solo/remote-meeting experience must stay exactly as before when
  new features (diarization, etc.) are off.
- **N6 — Permissions persist across updates.** Code signing uses a stable identity
  so macOS keeps TCC grants (Screen Recording, Accessibility, Mic) across rebuilds
  and updates.
- **N7 — Platform.** macOS 14+ (Sonoma) floor; Apple Silicon; not sandboxed (needed
  for ScreenCaptureKit system audio in a self-distributed build).
- **N8 — Verified by running.** Pure logic is unit-tested (TDD); framework/UI
  integrations are verified by building and running the real app (and, for UI,
  visually checked). Ship only what's verified.
- **N9 — Production-quality polish.** Clean, distinctive, non-generic UI;
  thoughtful empty/loading/error states; clear copy. Light **and** dark mode both
  look native.

---

## 4. Explicit non-goals / rejected ideas

- **Summarization** — intentionally removed; the app only transcribes.
- **Live (real-time) transcript** — was prototyped and **explicitly abandoned** by
  the owner as not worth it; the authoritative transcript stays a post-meeting
  pass.
- **Named in-room speakers without enrollment / a cloud service** — recognition is
  local and voiceprint-based only.
- **Cloud transcription / notarization-dependent distribution** — out of scope;
  the app is self-distributed and on-device.

---

## 5. Conventions

- **Commits:** Conventional Commits (`feat:`/`fix:`/`chore:`/`refactor:`/
  `docs:`/`build:`/`test:`). **Never** mention AI/Claude in commit messages.
- **Credentials:** never commit secrets; `.env`/keys/`.tfvars` stay out of git.

---

_This document records intent. When a requirement changes, update it here so it
stays the single source of truth for the product's behavior and feel._
