# Transcription time estimate (N10) — design

**Requirement:** N10 (communicated turnaround — a rough sense of how long a transcript will take)
**Date:** 2026-06-18
**Status:** Approved, ready for implementation plan

## Problem

The app already shows live transcription **progress** (R21): WhisperKit reports a real
fraction (`transcribed seconds / total audio seconds`) and the main-window detail pane
renders a progress bar + percentage. What's missing is the *time* framing N10 asks for —
the user can see "42%" but not "about how much longer." N10 wants a **rough sense of how
long a transcript will take**.

## Decisions (settled in brainstorming)

- **Live remaining-time only.** Derive "~N min left" from the live progress fraction +
  elapsed wall-time. No upfront (t=0) estimate, no per-engine throughput constants, no
  whole-queue ETA. (Those were considered and rejected as lower-value / calibration-heavy.)
- **Detail pane only.** Show the estimate next to the existing progress row in the main
  window. No menu-bar status change.
- **Roughness is acceptable and expected** — the estimate is explicitly approximate.

## Architecture

### 1. `TranscriptionETA` (pure logic, MeetingKit, TDD core)

A small pure type that turns the progress signal into a stable remaining-time label.

```swift
public struct TranscriptionETA {
    // Tunables (with sensible defaults):
    //   minFraction  — don't estimate until progress passes this (stability gate)
    //   minElapsed   — don't estimate until at least this much wall-time has passed
    //   smoothing    — EMA weight for new samples (0..1)
    public init(minFraction: Double = 0.03, minElapsed: TimeInterval = 3,
                smoothing: Double = 0.3)

    /// Feed one progress observation; returns the current friendly label, or nil
    /// if no stable estimate is available yet.
    public mutating func update(elapsed: TimeInterval, fraction: Double) -> String?

    /// Reset between meetings.
    public mutating func reset()
}
```

- **Estimate:** `remaining ≈ elapsed × (1 − f) / f`.
- **Smoothing:** an exponential moving average of `remaining` (the two audio channels
  report progress interleaved, so raw values are noisy; EMA absorbs that).
- **Gating:** returns `nil` until `fraction ≥ minFraction` AND `elapsed ≥ minElapsed`, so
  the first number shown is already stable — never a wild "~47 min" that collapses.
- **Upward-jump clamp:** the smoothed estimate may fall freely but only rise gently, so it
  reads as a countdown rather than bouncing up.
- **Friendly buckets** (from the smoothed seconds):
  - `≥ 90s` → `"~N min left"` (round to nearest minute)
  - `45–90s` → `"~1 min left"`
  - `20–45s` → `"under a minute"`
  - `< 20s` → `"almost done"`

Pure and fully unit-testable by feeding synthetic `(elapsed, fraction)` sequences — no
timers, no real transcription.

### 2. AppState wiring

- Record `transcriptionStartedAt: Date` when a meeting begins transcribing (in the
  existing `drainProcessingQueue`/`process` path, alongside the existing progress handler).
- Hold one `TranscriptionETA` for the in-flight meeting.
- In the existing progress callback, when `fraction != nil`, call
  `eta.update(elapsed: Date().timeIntervalSince(start), fraction: f)` and publish the
  result to a new `@Published private(set) var progressETA: String?`.
- Set `progressETA = nil` on start, finish, cancel, and whenever `fraction` is `nil`
  (model download, Parakeet's coarse 0→1, pre-first-segment).

### 3. UI (detail pane only)

- In the existing `progressRow` in `MainWindowView.swift`, when `state.progressETA != nil`,
  append it to the progress line — e.g. **"Transcribing… 42% · ~2 min left"**.
- When `nil`, the row renders exactly as today (no regression).

## Error handling / edge cases

All edge cases degrade to **no estimate** (never a wrong or alarming number):

- **Model download / pre-first-segment:** `fraction` is `nil` → no ETA; phase + spinner as
  today.
- **Parakeet fast path:** jumps 0→1 with no intermediate fraction → finishes near-instantly
  before a stable estimate forms; ETA stays `nil` (correct — it's effectively done).
- **Channel interleaving / a backward fraction step:** the EMA + gating threshold keep the
  displayed number stable; a transient backward step never produces a negative or jumping
  estimate.

## Testing

Pure / unit-tested (swift-testing), TDD:

- `TranscriptionETA`: steady progress → estimate decreases monotonically (within clamp);
  early samples (below gates) → `nil`; noisy/interleaved samples → stable output; the four
  rounding buckets at their boundaries; `reset()` clears state.

Verified by running (N8): during a real WhisperKit transcription the detail pane shows a
sensible, falling "~N min left"; Parakeet-only meetings show no ETA and finish fast; no
regression to the existing progress row when no estimate is available.

## Out of scope (YAGNI)

- Upfront (t=0) estimate from audio duration × per-engine throughput constants.
- Whole-queue "all transcripts done in ~N min" estimate.
- Menu-bar status change.
- Surfacing the estimate anywhere transcripts are exported or persisted.
