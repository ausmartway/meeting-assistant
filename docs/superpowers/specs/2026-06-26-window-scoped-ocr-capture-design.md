# Window-scoped OCR capture — design

**Date:** 2026-06-26
**Status:** Approved (brainstorming)
**Fixes:** OCR reads the whole screen instead of only the meeting window.

## Problem

The video capture stream is built from the whole **display**
(`CaptureSession.startVideoStream` → `SCContentFilter(display:…)`), so every frame
handed to `SpeakerSampler` contains the entire screen. OCR then detects tiles and
reads name labels from *any* window on screen — browser tabs, other apps, the
desktop — not just the meeting. Active-speaker names get polluted by unrelated
on-screen text.

## Goal

Scope OCR to the meeting window only. Capture **just the meeting window's pixels**
via ScreenCaptureKit window capture, so the frame `SpeakerSampler` reads *is* the
meeting and nothing else. When no meeting window can be identified, capture no
video at all (strict — never fall back to the whole screen).

The OCR's intent is to name the **current (active) remote speaker** — not to
harvest every name on screen. The active-speaker targeting already exists; this
work makes it reliable by confining capture to the meeting window. The "not
myself" half of the requirement is handled entirely on the **audio side** (mic
channel + voiceprints), not in OCR — see Component 4.

## Principles preserved

- **Cheap live capture, heavy post-processing.** Only the capture target changes;
  no work moves into the live path. `SpeakerSampler` is untouched.
- **Audio is independent and unchanged.** System audio is global and stays on its
  own display-based stream; this change never touches the mic/system split or the
  audio-route-change resilience.
- **Pure logic is unit-tested.** Window selection is pure and tested; the
  ScreenCaptureKit wiring is integration, verified by running the app.

## Components

### 1. `ScreenWindow` gains `windowID: CGWindowID` (`DisplaySelector.swift`)

The pure `ScreenWindow` adapter gets a stable `windowID` so a chosen pure window
can be mapped back to its real `SCWindow` at the capture boundary. Populated from
`SCWindow.windowID`.

### 2. New pure `DisplaySelector.pickWindow(...)` (`DisplaySelector.swift`)

```swift
static func pickWindow(
    windows: [ScreenWindow],
    preferredBundleIDs: Set<String>,
    frontmostPID: pid_t?
) -> ScreenWindow?
```

Returns the meeting window using the **existing rule** already inside `pickDisplay`:
the largest window owned by a preferred (conferencing-app) bundle ID; else the
largest window owned by the frontmost app; else `nil`. `pickDisplay` is refactored
to call `pickWindow` (then map the chosen window to its display) so both share one
selection rule. Behavior of `pickDisplay` is unchanged.

### 3. Window-scoped video capture (`CaptureSession.swift`)

- `startVideoStream(on window: SCWindow)` (was `on display: SCDisplay`) builds
  `SCContentFilter(desktopIndependentWindow: window)`. The stream is sized to the
  window's aspect ratio (window point size × backing scale, longest side capped at
  ~1920) with `config.scalesToFit = true`, so OCR gets an undistorted image of the
  window. Make-before-break (start new before stopping old) is preserved.
- `startSystemCapture` keeps the audio stream on the primary display (unchanged).
  For video: pick the meeting window; if found, start the window stream; if not
  found, **skip video capture** and log it. The retarget watcher always starts, so
  video can begin later if the window appears.
- State: `videoWindowID: CGWindowID?` replaces `videoDisplayID`.
- `meetingWindow(in: SCShareableContent) -> SCWindow?` helper (analogous to the
  existing `meetingDisplay`) maps the pure `pickWindow` result back to an
  `SCWindow` by `windowID`.

#### Retarget / reconcile watcher

Every ~5 s (`reconcileVideoTarget`):
1. Fetch `SCShareableContent`; on failure, return (keep current — transient).
2. `let window = meetingWindow(in: content)`.
3. If `window == nil`: the meeting window is gone — if a video stream is running,
   stop it and clear `videoWindowID` (strict: capture nothing). Return.
4. If `window.windowID == videoWindowID`: unchanged → return.
5. Otherwise start/rebuild the video stream on `window` (handles the window
   appearing for the first time, or a different window becoming the meeting).

ScreenCaptureKit follows a captured window across moves and displays
automatically, so cross-display retargeting is mostly handled for free; the
watcher only needs to react to the *identity* of the meeting window changing or
its appearance/disappearance.

### 4. `SpeakerSampler` — no change (already targets the *active* speaker)

`SpeakerSampler` OCRs only the chosen tile (the active-speaker highlight, or the
dominant tile in a 1-on-1) and returns a single name via `bestName`. It never
collects every name on screen. The whole-screen capture was why it *appeared* to
grab arbitrary names — unrelated bright rectangles elsewhere on the desktop could
win the highlight score. Window-scoping (Components 1–3) confines tile detection
to the meeting window and fixes this; **no logic change is needed here.**

#### Why no "self" detection belongs in OCR

The "name the current speaker *if it is not myself*" requirement is satisfied by
the **audio-channel split + voiceprints**, not by anything visual:

- **Mic channel** carries the local user *and anyone physically in the same room*.
  These are separated by diarization and identified by **voice fingerprints**
  (`SpeakerRecognizer.resolve` matches each mic cluster against the enrolled
  speaker library; the enrolled user has `isMe == true` and resolves to "Me",
  in-room others resolve to their known names or "Speaker N"). This is the
  existing in-room diarization feature.
- **System-audio channel** carries the remote participants. `SpeakerFuser` applies
  the OCR active-speaker timeline **only** to system-audio segments
  (`SpeakerFuser.fuse` → `case .system`).

Because the local user's voice is always on the mic channel and OCR names are only
ever applied to system-audio (remote) segments, OCR **structurally cannot** label
the local user's speech. Self-identification (including distinguishing the local
user from other in-room people) is the voiceprint system's job. We therefore add
**no** marker-based or name-based self-detection to the OCR path; doing so would
duplicate the voiceprint responsibility and rely on fragile per-app UI markers
(some apps don't even highlight or self-mark the local user's own tile).

## Data flow

```
meeting SCWindow  ──▶ SCContentFilter(desktopIndependentWindow:)
                  ──▶ video frames of ONLY the meeting window (~2 fps)
                  ──▶ SpeakerSampler OCR (unchanged)
```

## Edge cases

- **No meeting window at start:** no video stream; OCR yields no names; speakers
  degrade to "Speaker" (existing graceful path). Watcher starts video if/when the
  window appears.
- **Meeting window closes/minimizes mid-call:** reconcile stops video; resumes if
  it reappears. (A minimized window may stop delivering frames regardless.)
- **Multiple conferencing windows** (e.g. main window + screen-share window):
  largest wins, per the existing rule.
- **Transient `SCShareableContent` failure:** keep the current stream (no thrash).

## Testing

New/updated swift-testing (pure):
- `DisplaySelector.pickWindow` — largest preferred-bundle window wins; preferred
  beats frontmost; falls back to frontmost app's largest window; `nil` when
  neither matches; ties/area handling.
- Existing `DisplaySelector.pickDisplay` tests stay green after the refactor
  (update the `ScreenWindow` test factory to pass a `windowID`).

Integration (verified by running the app, not unit-tested): window-scoped
`SCContentFilter`, stream sizing, reconcile/retarget, and the strict no-window
behavior.

## Requirements impact

Add/adjust a requirement noting capture is **window-scoped** (privacy: the rest of
the desktop is never recorded) and that on-screen name OCR (R10b) reads only the
meeting window. Flag for `requirements-sync-reviewer`.

## Build order

1. `ScreenWindow.windowID` + `DisplaySelector.pickWindow` (+ tests; refactor
   `pickDisplay` to reuse it; fix existing tests).
2. `CaptureSession`: `meetingWindow(in:)` helper + window-based
   `startVideoStream(on:)` + sizing.
3. `CaptureSession`: `startSystemCapture` uses the window (skip when none) +
   `videoWindowID` state.
4. `CaptureSession`: `reconcileVideoTarget` watcher (start/rebuild/stop).
5. REQUIREMENTS.md note + requirements-sync check.
