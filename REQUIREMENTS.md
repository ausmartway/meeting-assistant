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
**macOS 26**) that watches the calendar, prompts to capture Zoom/Meet/Teams/Webex
meetings, and produces a **speaker-labeled transcript**, transcribed **locally** on Apple
Silicon. It only transcribes — summarization was intentionally removed.

---

## 2. Explicit functional requirements

### Capture & recording
- **R1 — Prompt to record.** When a calendar meeting starts and the user joins from
  the Zoom / Teams / Google Meet / Webex app, the app posts an actionable "Start
  recording?" notification (once per meeting); recording begins only when the user
  taps its **Start Recording** button. Recording never starts on its own. Manual
  "Record a meeting now" is always available.
- **R1b — Resilient microphone capture.** The local mic is captured reliably across
  audio **route changes** mid-meeting (e.g. AirPods/Bluetooth switching profiles
  when a call engages the mic) — the engine reconfigures and keeps recording instead
  of going silently dead. If the mic ever produces no audio, the app **warns the
  user** (menu bar + notification) within a few seconds so it can be fixed live
  rather than discovered afterwards.
- **R1d — Both channels monitored *(planned)*.** The same no-audio watchdog (R1b)
  must also cover the **system / remote-participant** channel: if no remote audio is
  captured for several seconds while recording, the app warns the user (menu bar +
  notification). Recording only your own voice for a whole meeting because the
  remote channel silently dropped is a silent catastrophe for a notes app; the
  recording indicator (R1c) should reflect that **both** channels are live.
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
- **R3c — Meeting names.** A recording is named after its **calendar invite subject**
  whenever one applies — including when "Record a meeting now" is pressed *during* a
  calendar meeting that is in progress. Otherwise it is a generic **"ad-hoc meeting"**.
  The app does **not** infer the provider from a merely-running app (Teams / Zoom /
  browsers run all day, which previously mislabeled in-room recordings as "Microsoft
  Teams meeting").
- **R3d — Rename a recording inline.** The user can rename a recording by **clicking
  its title and editing it in place** — no menus or dialogs. Auto-naming is
  best-effort; inline rename is the reliable correction, and it keeps the saved
  transcript heading in sync.
- **R1c — Visible recording state.** While recording, the app shows a clear,
  persistent indicator that capture is active (menu-bar icon + status, and in the
  main window), so the user is never unsure whether a meeting is being recorded.
- **R1e — Resilient prompting & back-to-back meetings *(planned)*.** Real meetings are
  messy, so a single fire-once notification isn't enough. For a detected, in-progress
  meeting the **"Record '<subject>'" action stays available for the whole meeting**
  (menu bar / main window), so a missed notification or a **late join** can still be
  recorded (it still inherits the calendar subject, R3c). **Consecutive meetings** are
  handled explicitly: recording does **not** auto-stop at the calendar end time
  (meetings overrun); when a new meeting is detected while one is recording, the app
  prompts for the new one and, on Start, cleanly finalizes the current recording and
  starts the next. Only **one meeting records at a time**.
- **R3e — Preserve interrupted recordings *(deprioritized)*.** If the app quits or the
  Mac sleeps mid-recording, the audio captured so far is preserved and can still be
  transcribed rather than lost. *(Deliberately deprioritized by the owner — not worth
  the cost/complexity of crash-safe incremental capture right now, since mid-recording
  app/Mac death is rare. Revisit only if it proves to happen in practice.)*

### Transcription quality
- **R4 — Readable transcripts.** Transcripts must read like real speech. Garbled or
  repeated runs (walls of one repeated character or word, e.g. `$$$$…` or
  `LAUGHTER LAUGHTER…`) and made-up filler during silence are removed.
- **R5 — Multilingual, automatic by default.** Transcription runs **locally** and, by
  default, **automatically uses the fastest engine that can handle each speaker's
  language** — so English (and other European languages) transcribe much faster while
  **Mandarin, and anything it's unsure about, stay accurate**. English and Mandarin
  are both first-class. Advanced users can force a specific engine in Settings; the
  Settings options are described by what they do for the user (speed vs.
  broad-language accuracy), not by internal model names. (Engine details:
  `docs/decisions/2026-06-17-transcription-engine.md`.)

### Speakers
- **R6 — In-room speaker separation (best-effort).** When the user is physically in
  a room with other people (all arriving on the single mic channel), the app
  **attempts to** separate the distinct in-room voices instead of labeling everyone
  "Me". This works only once the user has enrolled their own voice (R7) and is
  best-effort — it degrades to a single "Me" when it can't separate confidently.
- **R7 — "Me" via enrollment.** The user enrolls their own voice once by **reading
  an on-screen script** during initial setup (and re-doable in Settings); their
  enrolled voice is labeled "Me", others become "Speaker 2", "Speaker 3", ….
- **R8 — Name anonymous speakers, remembered locally.** The user can rename an
  anonymous speaker (e.g. "Speaker 2" → "Sam") from the transcript. The name is
  remembered locally.
- **R8b — Local user named, not "Me".** The local user is labeled by an **editable
  display name** (defaulting to the macOS account full name) instead of "Me", in
  transcripts and the UI; an existing "Me" enrollment is migrated to that name. The
  name is set/changed in Settings → Speakers.
- **R9 — Cross-meeting recognition.** Naming a speaker stores that voice's print in
  a **local speaker library**, so the same person is auto-recognized by name in
  future meetings. The local user is just the enrolled member of that library.
  Exception: when the renamed cluster has too little total speech to be a
  trustworthy voiceprint (`SpeakerRecognizer.minSpeechDuration`), the transcript
  rename still applies but the library is **not** taught — a junk/noise cluster
  must never poison a known speaker's voiceprint (see N4).
- **R9c — Self-improving voiceprints.** A known speaker's print is a small set of
  voice samples (bounded; distinct voice modes like headset vs meeting room are
  preserved by merging the closest pair at the cap). Every confidently-attributed
  cluster — an automatic match or an explicit rename that clears the trust gates —
  enriches that speaker's print, so recognition improves with exposure and no
  single meeting can dominate or corrupt a print.
- **R10 — Conservative matching.** Only **confident** voice matches are auto-named;
  weak matches stay anonymous rather than risk the wrong name. A known name is
  assigned by the nearest of the speaker's stored voice samples, and only when (a) it
  clearly beats the next-nearest different speaker (a margin), so an ambiguous
  voiceprint never grabs a wrong name, and (b) the cluster has enough total speech
  behind it — a few seconds of noise can embed arbitrarily close to a real voiceprint
  by chance, so short clusters stay anonymous ("Speaker N") regardless of match
  distance.
- **R10c — Re-transcribe re-recognizes.** Re-transcribing a meeting clears its
  previous per-meeting speaker identifications and recognizes speakers afresh; the
  cross-meeting speaker library (R9) is preserved.
- **R10b — Best-effort on-screen names.** When a remote participant's name is shown
  on screen, the app reads that on-screen name label to identify them — including a
  **single** remote participant with no active-speaker highlight (a 1-on-1 / speaker
  view). This is best-effort (it varies by app, theme, and layout) and degrades to
  "Speaker"; renaming (R8) is always the reliable fallback. The UI should set this
  expectation so an unnamed speaker doesn't read as a failure.
  On-screen reads are made more reliable by post-processing: low-confidence OCR is
  rejected, trivial name variants (whitespace, "(Host)"/"(You)", case) are merged,
  and isolated single-frame misreads are voted out across samples
  (`SpeakerTimelineConsolidator`, `SpeakerNameNormalizer`).
  Capture is **window-scoped**: only the meeting window's pixels are recorded for
  OCR (the rest of the desktop is never captured), and when no meeting window is
  found nothing is captured. When the on-screen active-speaker name is **not
  confidently a human name** (a shared room/device endpoint), the remote speaker is
  identified by **voice fingerprint** instead — the system-audio channel is diarized
  (lazily, only then) and its clusters resolved against the speaker library
  (`HumanNameClassifier`, `DisplaySelector.pickWindow`). Local and in-room speakers
  remain identified by voiceprint on the mic channel (R9).

### Transcripts, history & management
- **R19 — Persistent history.** Finished meetings are saved and listed in the main
  window (most recent first) and remain available across app restarts; selecting one
  reopens its transcript.
- **R19b — Recurring meetings keep separate history.** Each occurrence of a
  recurring calendar event (e.g. a weekly sync) is a distinct meeting with its own
  recording bundle and transcript; recording one occurrence must never overwrite or
  merge with another occurrence of the same series. (EventKit reuses one
  `eventIdentifier` across a series, so meeting identity is keyed by event *and*
  occurrence start time — `Meeting.occurrenceID`.)
- **R20 — Delete a recording.** The user can delete a recording — its audio, sampled
  frames, and transcript — from the GUI (with confirmation), which frees the disk
  space it used.
- **R21 — Progress & "ready".** The app shows transcription progress per meeting
  (current stage, and how many are queued behind it) and notifies the user when a
  transcript is **ready**.
- **R22 — Export & copy.** A transcript can be copied to the clipboard as plain text,
  saved to a file (Markdown), or revealed in Finder.
- **R23 — Search history.** A search field on the sidebar filters past meetings as the
  user types — matching the meeting name, its date, and the transcript text. Matching
  runs against an in-memory index (rebuilt as recordings change; transcript text folded
  in off the main thread), the in-progress recording stays pinned, and a clear
  "no matches" state shows when nothing matches.
- **R26 — Tiered retention: expire recordings, keep transcripts.** Recording audio is
  **large**, so it is cleared automatically after its retention window (default 7
  days). The **transcript is tiny and is kept much longer** — it survives the
  recording it came from (default 1 year). Both windows are **user-configurable in
  Settings → Storage with reasonable defaults** (and a "Never" option), so it works
  out-of-the-box without setup but power users can tune or disable it. A retention
  sweep runs at launch and daily, skipping any meeting that is recording or
  transcribing. After a recording's audio is reclaimed, its transcript stays readable
  in history; only "Make Transcript Again" (which needs the audio) becomes
  unavailable, and the UI says so ("Audio cleared to save space") rather than failing
  silently. **Recognized speakers' voiceprints are never removed** — they live in the
  global speaker library outside any meeting folder, so cross-meeting recognition (R9)
  survives expiry. Manual delete (R20) still removes everything immediately.

### Setup & permissions
- **R24 — Guided first run.** On first launch the app walks the user, in plain
  language, through approving the app (the one-time Gatekeeper "Open
  Anyway"), granting the permissions it needs (Microphone, Screen & System Audio,
  Calendar, Notifications, Accessibility), and enrolling their voice.
- **R25 — Clear permission state, never silent.** If a required permission is missing
  or denied, the app clearly says what is blocked and offers a direct path to the
  correct System Settings pane; core actions never fail silently.

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
- **R13b — Verify a line against its audio *(planned)*.** Local transcription
  mishears names, jargon, and numbers, and a confidently-wrong line is dangerous once
  pasted into a client follow-up. While the audio still exists (before retention
  expiry, R26), the user can **click a transcript line to play that audio segment** and
  check/fix it. This makes the "best-effort" nature honest rather than silently
  authoritative; once audio is cleared, playback is simply unavailable.
- **R14 — Distinctive app icon.** A custom icon (microphone + waveform on a
  blue→indigo squircle), not the generic default.
- **R15 — Discoverable setup.** Voice enrollment and settings are reachable from
  the menu bar (no hunting); Settings toggles must visibly take effect.
- **R16 — Dock app.** Ships as a Dock-first app (Dock icon on by default) while
  keeping the menu-bar item as a lightweight status + quick-record companion.
- **R16b — Actions are visible buttons, not menus.** Actions a user performs on a
  selected recording (Copy, Export/Save, Reveal, Make Transcript Again, Delete,
  rename, etc.) are exposed as **clearly labeled buttons in the right-hand detail
  pane**, not tucked into context menus, menu-bar submenus, or right-click menus.
  Buttons are discoverable and lower-effort for end-users; hidden menus are not.
  (Menus may still mirror an action as a convenience, but the button is the
  primary, always-visible path.)

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
- **N1b — Participant consent is the user's responsibility *(planned)*.** N1 protects
  *the user's* privacy; this protects *the people they record*. The app captures other
  participants' audio, so it must (a) **never record covertly** — recording always has
  the visible indicator (R1c) — and (b) on first run, and as a one-line reminder near
  the Record action, make clear that the user is responsible for obtaining recording
  consent where law/policy requires it. Optionally offer a "remind me to tell
  participants" nudge. This keeps the tool trustworthy and IT/legal-safe.
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
- **N7 — Platform.** macOS 26+ (Tahoe) floor; Apple Silicon; not sandboxed (needed
  for ScreenCaptureKit system audio in a self-distributed build). Earlier macOS
  versions are deliberately unsupported — the owner targets current-OS Macs only.
- **N8 — Verified by running.** Pure logic is unit-tested (TDD); framework/UI
  integrations are verified by building and running the real app (and, for UI,
  visually checked). Ship only what's verified.
- **N9 — Production-quality polish.** Clean, distinctive, non-generic UI;
  thoughtful empty/loading/error states; clear copy. Light **and** dark mode both
  look native.
- **N10 — Communicated turnaround.** The user gets a rough sense of how long a
  transcript will take and sees live progress; transcription completes within a
  reasonable multiple of the meeting length on supported Apple Silicon. The detail
  pane shows a smoothed "~N min left" estimate next to the progress bar during
  transcription (it appears once progress is stable, and is omitted for the
  near-instant Parakeet path).
- **N11 — Manageable storage.** Recordings (audio + transcripts) must not grow
  unbounded without the user's awareness; the user can see and reclaim space, and
  long-term retention is manageable. The heavy artifact (audio) carries a short
  default retention and ages out automatically; lightweight transcripts are retained
  far longer (see R26). Storage used is shown both in Settings → Storage and in the
  main-window sidebar footer, with a "Clean up now" action and per-recording delete
  (R20).
- **N12 — Long meetings don't fail.** Multi-hour meetings capture and transcribe
  without running out of memory or failing; live capture stays lightweight
  throughout (see N2).
- **N13 — Multi-display name reading.** On-screen name reading works when the meeting
  window is on a secondary display, and follows the window if it moves displays
  mid-meeting. Video-frame capture targets the meeting window itself: among windows
  owned by a preferred (conferencing-app) bundle ID, one whose title matches the
  calendar meeting's subject wins over raw window size — a bigger main-app or
  browser window that isn't the meeting must not outrank it — falling back to the
  largest preferred window, then the frontmost app's largest window. System-audio
  capture runs on its own independent stream so re-targeting never interrupts it.

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
