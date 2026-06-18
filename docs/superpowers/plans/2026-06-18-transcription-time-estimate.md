# Transcription Time Estimate (N10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a rough "~N min left" estimate next to the transcription progress bar, derived from the live progress fraction + elapsed time.

**Architecture:** A pure `TranscriptionETA` (MeetingKit) turns a stream of `(elapsed, fraction)` samples into a smoothed, friendly remaining-time label. `AppState` records the transcription start time, feeds the estimator from its existing progress callback, and publishes `progressETA: String?`. The detail-pane `progressRow` appends the label to the existing percentage. Detail pane only; no menu-bar change.

**Tech Stack:** Swift, SwiftUI, swift-testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-06-18-transcription-time-estimate-design.md`

---

## File structure

- **Create** `Sources/MeetingKit/TranscriptionETA.swift` — pure estimator + label formatting.
- **Modify** `Sources/MeetingAssistant/AppState.swift` — `progressETA` published; start-time + estimator; feed from progress callback; reset points.
- **Modify** `Sources/MeetingAssistant/MainWindowView.swift` — append ETA to the progress percentage line.
- **Create** `Tests/MeetingKitTests/TranscriptionETATests.swift`.
- **Modify** `REQUIREMENTS.md` — mark N10 implemented.

Reminder for all tasks: this repo uses **4-space indentation** (pinned by `.swift-format`). When committing, stage only the files you changed by explicit path; never `git add -A` or stage anything under `.claude/`. No AI/Claude mentions or Co-Authored-By trailers in commit messages.

---

## Task 1: `TranscriptionETA` pure estimator

**Files:**
- Create: `Sources/MeetingKit/TranscriptionETA.swift`
- Test: `Tests/MeetingKitTests/TranscriptionETATests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite struct TranscriptionETATests {
    // Default gates: minFraction 0.03, minElapsed 3, smoothing 0.3.

    @Test func noEstimateBeforeGates() {
        var eta = TranscriptionETA()
        // fraction below minFraction → no estimate yet
        #expect(eta.update(elapsed: 5, fraction: 0.01) == nil)
        // elapsed below minElapsed → no estimate yet
        #expect(eta.update(elapsed: 1, fraction: 0.5) == nil)
    }

    @Test func steadyProgressCountsDown() {
        var eta = TranscriptionETA()
        // 10s elapsed, 25% done → raw = 10*(0.75/0.25) = 30s  → "under a minute"
        let a = eta.update(elapsed: 10, fraction: 0.25)
        // 20s elapsed, 50% done → raw = 20*(0.5/0.5) = 20s (falls freely) → "under a minute"
        let b = eta.update(elapsed: 20, fraction: 0.50)
        // 30s elapsed, 75% done → raw = 30*(0.25/0.75) = 10s (falls freely) → "almost done"
        let c = eta.update(elapsed: 30, fraction: 0.75)
        #expect(a == "under a minute")   // 30s → 20..45 bucket
        #expect(b == "under a minute")   // 20s → 20..45 bucket (boundary)
        #expect(c == "almost done")      // 10s → <20
    }

    @Test func upwardBlipIsDamped() {
        var eta = TranscriptionETA()
        // Establish a low estimate: 30s elapsed, 90% done → raw ~3.3s
        _ = eta.update(elapsed: 30, fraction: 0.90)
        // A noisy backward fraction (interleaved channels): 31s, 50% → raw=31s.
        // Must NOT jump straight to a ~31s estimate; gentle rise only.
        let after = eta.update(elapsed: 31, fraction: 0.50)
        // prev ~3.33; gentle rise = prev + 0.3*(31-3.33) ≈ 11.6s → "almost done"
        #expect(after == "almost done")
    }

    @Test func minutesBucketRoundsToNearest() {
        // ≥90s → "~N min left" rounded to nearest minute.
        #expect(TranscriptionETA.label(for: 90) == "~2 min left")    // 1.5 → 2
        #expect(TranscriptionETA.label(for: 130) == "~2 min left")   // 2.17 → 2
        #expect(TranscriptionETA.label(for: 200) == "~3 min left")   // 3.33 → 3
    }

    @Test func subMinuteBuckets() {
        #expect(TranscriptionETA.label(for: 80) == "~1 min left")    // 45..90
        #expect(TranscriptionETA.label(for: 45) == "~1 min left")    // boundary
        #expect(TranscriptionETA.label(for: 30) == "under a minute") // 20..45
        #expect(TranscriptionETA.label(for: 20) == "under a minute") // boundary
        #expect(TranscriptionETA.label(for: 10) == "almost done")    // <20
    }

    @Test func resetClearsState() {
        var eta = TranscriptionETA()
        _ = eta.update(elapsed: 10, fraction: 0.25)
        eta.reset()
        // After reset, a below-gate sample yields nil again (no carried estimate).
        #expect(eta.update(elapsed: 1, fraction: 0.5) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptionETATests`
Expected: FAIL — `cannot find 'TranscriptionETA' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Turns a stream of transcription progress observations into a smoothed,
/// human-friendly "time remaining" label. Pure and deterministic: the caller
/// supplies `elapsed` (wall-time since transcription started) and the live
/// `fraction` (0...1), so there are no timers or clocks inside — which makes the
/// smoothing and rounding fully unit-testable.
///
/// Design (see spec N10):
///  • remaining ≈ elapsed × (1 − f) / f
///  • a gate (minFraction / minElapsed) suppresses the wild early estimates
///  • the smoothed value falls freely but rises only gently, so channel-
///    interleaving noise can't make the countdown jump upward.
public struct TranscriptionETA {
    private let minFraction: Double
    private let minElapsed: TimeInterval
    private let smoothing: Double
    private var smoothedRemaining: TimeInterval?

    public init(minFraction: Double = 0.03, minElapsed: TimeInterval = 3, smoothing: Double = 0.3) {
        self.minFraction = minFraction
        self.minElapsed = minElapsed
        self.smoothing = smoothing
    }

    /// Clear all state between meetings.
    public mutating func reset() { smoothedRemaining = nil }

    /// Feed one progress observation; returns the current friendly label, or nil
    /// if no stable estimate is available yet.
    public mutating func update(elapsed: TimeInterval, fraction: Double) -> String? {
        // Below the gates (too early, or not enough progress, or already complete):
        // don't compute a new estimate, but keep showing the last stable one if any.
        guard fraction >= minFraction, fraction < 1, elapsed >= minElapsed else {
            return smoothedRemaining.map(Self.label(for:))
        }
        let raw = elapsed * (1 - fraction) / fraction
        if let prev = smoothedRemaining {
            // Fall freely; rise gently (EMA toward the higher raw value).
            smoothedRemaining = raw < prev ? raw : prev + smoothing * (raw - prev)
        } else {
            smoothedRemaining = raw
        }
        return smoothedRemaining.map(Self.label(for:))
    }

    /// Map a remaining-seconds value to a rough, friendly label.
    public static func label(for seconds: TimeInterval) -> String {
        if seconds >= 90 {
            let mins = Int((seconds / 60).rounded())
            return "~\(mins) min left"
        } else if seconds >= 45 {
            return "~1 min left"
        } else if seconds >= 20 {
            return "under a minute"
        } else {
            return "almost done"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TranscriptionETATests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/TranscriptionETA.swift Tests/MeetingKitTests/TranscriptionETATests.swift
git commit -m "feat: add TranscriptionETA estimator for transcription time remaining"
```

---

## Task 2: Wire the estimate into AppState

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift`

No unit test (`@MainActor` coordinator; verified by build + running). The pure estimator is covered in Task 1.

- [ ] **Step 1: Add the published label + estimator state**

In `Sources/MeetingAssistant/AppState.swift`, right after the existing progress
properties:

```swift
    @Published private(set) var progressFraction: Double?
    @Published private(set) var progressPhase: String?
```

add:

```swift
    /// A rough "time remaining" label for the in-flight transcription (e.g.
    /// "~2 min left"), or nil when no stable estimate is available yet. Detail pane only.
    @Published private(set) var progressETA: String?

    /// Estimator state + clock for the current transcription. `eta` smooths the
    /// remaining-time; `transcriptionStartedAt` is when the current meeting began.
    private var eta = TranscriptionETA()
    private var transcriptionStartedAt: Date?
```

- [ ] **Step 2: Start the clock + feed the estimator in `process(_:)`**

In `process(_ meeting:)`, immediately after the `guard let recording = … else { return }`
block (before building the `processor`), start the clock:

```swift
        // Start the time-remaining clock for this meeting.
        transcriptionStartedAt = Date()
        eta.reset()
        progressETA = nil
```

Then change the existing progress callback from:

```swift
        let progress: MeetingProcessor.ProcessProgress = { [weak self] fraction, phase in
            Task { @MainActor in
                self?.progressFraction = fraction
                self?.progressPhase = phase
            }
        }
```

to also update the ETA:

```swift
        let progress: MeetingProcessor.ProcessProgress = { [weak self] fraction, phase in
            Task { @MainActor in
                guard let self else { return }
                self.progressFraction = fraction
                self.progressPhase = phase
                // Only a real transcription fraction yields a time estimate; model
                // download / coarse 0→1 (Parakeet) / pre-first-segment leave it nil.
                if let fraction, let start = self.transcriptionStartedAt {
                    self.progressETA = self.eta.update(
                        elapsed: Date().timeIntervalSince(start), fraction: fraction)
                } else {
                    self.progressETA = nil
                }
            }
        }
```

- [ ] **Step 3: Clear the estimate when an item finishes**

In `drainProcessingQueue()`, the per-item reset block currently reads:

```swift
                progressFraction = nil
                progressPhase = nil
```

Change it to also clear the ETA:

```swift
                progressFraction = nil
                progressPhase = nil
                progressETA = nil
                transcriptionStartedAt = nil
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: publish a transcription time-remaining estimate from AppState"
```

---

## Task 3: Show the estimate in the detail pane

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

No unit test (SwiftUI view; verified by running).

- [ ] **Step 1: Append the ETA to the percentage line**

In `MainWindowView.swift`, the `progressRow` computed property has a line that renders
the percentage:

```swift
                    Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
```

Change it to append the estimate when present (so it reads e.g. "42% · ~2 min left",
and stays exactly "42%" when there's no estimate — no regression):

```swift
                    Text("\(Int(fraction * 100))%" + (state.progressETA.map { " · \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Run to verify behavior**

Run: `./Scripts/build-app.sh --run`. Record (or re-transcribe via "Make Transcript
Again" on) a meeting with a few minutes of audio using the WhisperKit engine (Settings →
Models → force WhisperKit if needed, since Parakeet is near-instant). Watch the detail
pane: after a few seconds the progress line should read "Transcribing… NN% · ~N min left"
with the estimate falling as it progresses. A Parakeet-only run shows just the percentage
(no ETA), which is correct.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift
git commit -m "feat: show time-remaining estimate next to transcription progress"
```

---

## Task 4: Full verification + requirement status

**Files:**
- Modify: `REQUIREMENTS.md`

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: all suites pass, including `TranscriptionETATests`.

- [ ] **Step 2: Mark N10 implemented**

In `REQUIREMENTS.md`, the **N10** entry currently reads:

```
- **N10 — Communicated turnaround *(planned)*.** The user gets a rough sense of how
  long a transcript will take and sees live progress; transcription completes within
  a reasonable multiple of the meeting length on supported Apple Silicon. *(Live
  progress exists today (R21); an explicit time estimate does not.)*
```

Replace it with:

```
- **N10 — Communicated turnaround.** The user gets a rough sense of how long a
  transcript will take and sees live progress; transcription completes within a
  reasonable multiple of the meeting length on supported Apple Silicon. The detail
  pane shows a smoothed "~N min left" estimate next to the progress bar during
  transcription (it appears once progress is stable, and is omitted for the
  near-instant Parakeet path).
```

- [ ] **Step 3: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: mark N10 (transcription time estimate) as implemented"
```

---

## Self-review notes

- **Spec coverage:** `TranscriptionETA` estimator with EMA + fall-freely/rise-gently +
  gates + buckets (Task 1) ✓; AppState start-clock, feed-from-callback, publish
  `progressETA`, reset points (Task 2) ✓; detail-pane percentage+ETA line (Task 3) ✓;
  Parakeet/model-download/pre-segment all leave ETA nil via the `if let fraction` guard
  (Task 2) ✓; REQUIREMENTS N10 updated (Task 4) ✓.
- **Out of scope (per spec):** upfront/t=0 estimate, whole-queue ETA, menu-bar change.
- **Type consistency:** `TranscriptionETA.init(minFraction:minElapsed:smoothing:)`,
  `update(elapsed:fraction:) -> String?`, `reset()`, static `label(for:)`;
  `AppState.progressETA`, `eta`, `transcriptionStartedAt` — used consistently across
  tasks. `MeetingProcessor.ProcessProgress` is `(_ fraction: Double?, _ phase: String)`,
  so `fraction` is optional in the callback (handled by `if let fraction`).
- **Note on one test expectation:** in `steadyProgressCountsDown`, the first sample
  (10s, 25% → 30s remaining) lands in the 20..45 "under a minute" bucket; the comment in
  the test spells out each raw value so the implementer can confirm the bucket math.
