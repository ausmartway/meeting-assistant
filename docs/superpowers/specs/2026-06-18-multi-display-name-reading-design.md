# Multi-display name reading (N13) — design

**Requirement:** N13 (on-screen name reading also works when the meeting window is on a secondary display)
**Date:** 2026-06-18
**Status:** Approved, ready for implementation plan

## Problem

`SpeakerSampler` reads on-screen participant names by OCR'ing a captured video
frame. Today `CaptureSession.startSystemCapture` builds its `SCContentFilter` from
`content.displays.first` — it always captures **display #1**. When the meeting
window is on a **secondary display**, the sampled frame shows the wrong screen, so
no names are read. (Names are best-effort regardless; this just makes the best-effort
path work across displays.)

The system capture serves two roles:
- **System audio** — global; works no matter which display the filter names. This is
  the load-bearing path (per CLAUDE.md: mic+system audio is the authoritative signal).
- **Video frames** — display-specific; only feed best-effort OCR.

## Decisions (settled in brainstorming)

- **Display-selection strategy:** the meeting app's window first, else the frontmost
  window, else display #1 (graceful fallback).
- **Track mid-meeting moves:** yes — re-target the video capture when the meeting
  window moves to another display.
- **Protect audio at all costs:** re-targeting must never interrupt or drop system
  audio.

## Architecture

### 1. Split the single capture stream into two (CaptureSession)

Replace the one combined audio+video `SCStream` with two:

- **Audio stream** — `SCContentFilter(display: displays.first…)`,
  `capturesAudio = true`, `excludesCurrentProcessAudio = true`, sampleRate 16 kHz,
  **no video output**. Started once at recording start, **never restarted**, writes
  `system.wav`. (System audio is global, so the specific display in this filter does
  not matter.)
- **Video stream** — `SCContentFilter(display: <meeting's display>)`,
  `capturesAudio = false`, 1280×720, ~2 fps (`minimumFrameInterval` 1/2 s), screen
  output only. Feeds `SpeakerSampler`. This stream is **re-targetable**: it can be
  stopped and rebuilt on a different display.

Because audio lives on its own never-restarted stream, re-targeting the video stream
**cannot** drop or gap system audio. This is the core safety property of the split.

### 2. Re-target watcher (CaptureSession)

A lightweight repeating task (~every 5 s) that:
1. Queries `SCShareableContent` for current windows + displays.
2. Adapts them to pure structs and calls `DisplaySelector.pickDisplay(...)`.
3. If the chosen display id differs from the video stream's current display, stops
   the video stream and starts a fresh one on the new display. Audio stream untouched.
4. If no meeting window is found, keeps the current display (no thrashing).

The watcher is best-effort: any failure (content query throws, rebuild fails) is
logged and leaves the existing video stream running.

### 3. Pure `DisplaySelector` (MeetingKit, TDD core)

All decision logic, free of ScreenCaptureKit types so it is unit-testable:

```swift
import CoreGraphics

/// A captured on-screen window, adapted from SCWindow.
public struct ScreenWindow: Equatable, Sendable {
    public let frame: CGRect
    public let bundleID: String?
    public let pid: pid_t
    public init(frame: CGRect, bundleID: String?, pid: pid_t)
    public var area: CGFloat { frame.width * frame.height }
}

/// A display, adapted from SCDisplay.
public struct ScreenDisplay: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let frame: CGRect
    public init(id: CGDirectDisplayID, frame: CGRect)
}

public enum DisplaySelector {
    /// Pick the display showing the meeting: the largest window owned by a preferred
    /// (conferencing-app) bundle ID → its display; else the largest window owned by
    /// the frontmost app → its display; else nil (caller keeps display #1).
    public static func pickDisplay(
        windows: [ScreenWindow],
        displays: [ScreenDisplay],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?
    ) -> CGDirectDisplayID?

    /// Which display's frame contains `point`; if none strictly contains it, the
    /// display with the largest overlap toward it, else nil. Pure geometry.
    public static func display(containing point: CGPoint, in displays: [ScreenDisplay]) -> CGDirectDisplayID?
}
```

Selection detail: a window maps to a display via its **center point**
(`display(containing: window.frame.center, in:)`). "Largest" = greatest `area`.

### 4. Provider → bundle IDs (shared, no drift)

`MeetingDetector` already holds per-provider bundle-id lists (Zoom `us.zoom.xos`;
Teams; Webex; browsers for Meet/Webex) as private static arrays. Lift these into a
single public source of truth — a `MeetingProvider.meetingAppBundleIDs: Set<String>`
computed property in `Models.swift` — and have `MeetingDetector` read from it instead
of its own private copies, so the detector and the capture path can't drift.
`CaptureSession` passes the current meeting's `provider?.meetingAppBundleIDs ?? []` as
`preferredBundleIDs`; `frontmostPID` comes from
`NSWorkspace.shared.frontmostApplication?.processIdentifier`.

## Error handling / edge cases (all degrade safely — N3)

- **Single display:** `pickDisplay` returns it (or nil → display #1); watcher never
  rebuilds. Equivalent to today plus the audio/video split.
- **Browser meetings (Meet/Webex):** the browser window is the target; if ambiguous,
  frontmost fallback; if nothing, display #1. Names stay best-effort.
- **Meeting window minimized / not found:** keep the current display (no thrash).
- **Re-target failure:** logged; the existing video stream keeps running.
- **Audio is never affected** by any of the above (separate stream).

## Testing

- **`DisplaySelector`** unit-tested (swift-testing), pure:
  - preferred-app window wins over a larger non-preferred window;
  - frontmost-app fallback when no preferred window exists;
  - `nil` when neither matches;
  - largest-window tiebreak among multiple preferred windows;
  - `display(containing:in:)` returns the containing display, the max-overlap display
    when a point sits in a gap, and `nil` for empty displays.
- **`MeetingProvider.meetingAppBundleIDs`** unit-tested: each provider maps to the
  expected bundle IDs (and matches what `MeetingDetector` uses).
- **Integration (two streams, watcher, rebuild)** is verified by **running** on a real
  two-display Mac (per N8) and reviewed by the **capture-path-reviewer** subagent
  against the CLAUDE.md capture invariants. Not unit tested.

## Out of scope (YAGNI)

- Capturing multiple displays simultaneously.
- Per-window (rather than per-display) cropping of the OCR frame.
- Tracking moves faster than the ~5 s watcher tick.
- Any change to mic capture, the audio format, or the transcription pipeline.
