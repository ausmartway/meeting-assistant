# Slide Capture (R28) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a shared screen is presented in a meeting, save a keyframe image each time
its content materially changes, and show those images inline in the transcript at the
moment they appeared.

**Architecture:** Reuse the video frame `CaptureSession` already samples every 2.5 s for
speaker OCR. Reduce each frame to a 16×16 grey signature and save it as a keyframe when it
is *holding still* (barely differs from the previous sample) yet *new* (differs a lot from
the last keyframe) — so slides and documents are captured and talking heads are not. The
decision rule is a pure struct; the CoreImage/file work sits in an actor so it stays off
the serial ScreenCaptureKit delivery queue. Keyframes are listed in `recording.json`,
written into the transcript as Markdown image lines by `TranscriptFormatter`, recovered by
`TranscriptParser` into a list separate from `turns`, and rendered inline by the reading
view.

**Tech Stack:** Swift 6 / SwiftUI, macOS 26 deployment target, SPM (`MeetingKit` library +
`MeetingAssistant` executable), swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`),
ScreenCaptureKit, CoreImage, AVFoundation.

**Spec:** `docs/superpowers/specs/2026-08-20-slide-capture-design.md`

## Global Constraints

- **Deployment target macOS 26**; Apple Silicon; app is **not sandboxed**.
- **Toolchain:** full Xcode must be active — `xcode-select -p` must point inside
  `/Applications/Xcode.app`. Build with `swift build`, test with `swift test`.
- **N2 — cheap live capture:** no expensive work on ScreenCaptureKit's delivery queue.
  `outputQueue` (`Sources/MeetingKit/CaptureSession.swift:41`) is **serial** and serves
  **both** audio (`:297`) and screen (`:327`) outputs. Signature computation, JPEG
  encoding, and file writes MUST happen inside the `Task` that `handleVideoFrame` already
  spawns — never inline in the handler.
- **N3 — best-effort, never fatal:** any slide-capture failure is swallowed and logged; it
  must never break capture, the recording, or the transcript.
- **N5 — no regressions:** a meeting with no screen share must produce a `transcript.md`
  **byte-identical** to today's, and `TranscriptParser.Parsed.turns` must be unchanged for
  a document without slide lines.
- **Language/UI:** UI strings are **English-only**. No localization.
- **Commits:** Conventional Commits (`feat:`/`fix:`/`test:`/`docs:`/`refactor:`/`chore:`).
  **Never** mention AI/Claude in commit messages, and add no `Co-Authored-By` trailer.
- **Detection constants (from the spec):** `stillThreshold = 0.02`,
  `changeThreshold = 0.10`, `minInterval = 5` seconds, `maxKeyframes = 300`.
  Task 1 calibrates the two thresholds against real meetings and may revise them.
- **JPEG:** quality `0.7`, at the frame's existing resolution (already capped to a 1920 px
  long side by `CaptureSession.captureSize`).
- **Keyframe filename:** `slide-<zero-padded whole-second offset>.jpg`, e.g.
  `slide-0391.jpg`, stored in the bundle's `slides/` subdirectory. Manifest paths are
  stored **relative to the bundle** (`"slides/slide-0391.jpg"`).

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Sources/MeetingKit/SlideChangeDetector.swift` | Pure decision rule + `FrameSignature`. No frameworks. |
| `Sources/MeetingKit/SlideRecorder.swift` | `actor`: pixel buffer → signature → decide → JPEG write; accumulates `[SlideKeyframe]`. |
| `Tests/MeetingKitTests/SlideChangeDetectorTests.swift` | Detector rule tests. |
| `Tests/MeetingKitTests/SlideKeyframeDecodingTests.swift` | `MeetingRecording` back-compat decode. |
| `Tests/MeetingKitTests/SlideTranscriptTests.swift` | Formatter interleaving + parser recovery. |

**Modified:**

| Path | Change |
|---|---|
| `Sources/MeetingKit/Models.swift` | Add `SlideKeyframe`; add `slides` to `MeetingRecording` with a back-compat `init(from:)`. |
| `Sources/MeetingKit/CaptureSession.swift` | `capturesSlides` flag; build the recorder; one `await` in the existing frame `Task`; include slides in `stop()`. |
| `Sources/MeetingKit/MeetingStore.swift` | Non-creating `slidesDirectory(for:)`. |
| `Sources/MeetingKit/TranscriptFormatter.swift` | `document(…slides:)` emits Markdown image lines interleaved by offset. |
| `Sources/MeetingKit/TranscriptParser.swift` | Recognize image lines into `Parsed.slides`, leaving `turns` untouched. |
| `Sources/MeetingKit/MeetingProcessor.swift` | Pass `recording.slides` through to the formatter. |
| `Sources/MeetingAssistant/Settings.swift` | `captureSlides` preference, default on. |
| `Sources/MeetingAssistant/SettingsView.swift` | "Capture shared screens" toggle in the General tab. |
| `Sources/MeetingAssistant/AppState.swift` | Pass the setting to `CaptureSession`; add `slidesDirectory(for:)`. |
| `Sources/MeetingAssistant/MainWindowView.swift` | Render slides inline in `TranscriptReadingView`. |
| `REQUIREMENTS.md` | New R28; amend R26 and N1b. |
| `CLAUDE.md` | Note the slide-capture path and its tested pure modules. |

**Dependency order:** Task 1 (calibration) → 2 (detector) → 3 (models) → 4 (recorder) →
5 (capture wiring) → 6 (formatter) → 7 (parser) → 8 (processor) → 9 (store+settings) →
10 (UI) → 11 (docs).

---

## Task 1: Calibrate the thresholds against a real meeting

The rule rests on an unmeasured empirical claim: a talking-head gallery never scores below
`stillThreshold` between samples 2.5 s apart, while shared content reliably does. This
task replaces two reasoned guesses with two measured numbers. **The probe is throwaway
code — it is reverted at the end of this task, not shipped.**

**Files:**
- Modify (temporarily, then revert): `Sources/MeetingKit/CaptureSession.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: measured values for `stillThreshold` and `changeThreshold`, recorded in this
  plan file as a note under this task. Task 2 uses them.

- [ ] **Step 1: Add a temporary signature-logging probe**

In `Sources/MeetingKit/CaptureSession.swift`, add these two temporary members to the class:

```swift
    // TEMPORARY CALIBRATION PROBE — remove before shipping (plan Task 1).
    private var probeLastSignature: [UInt8]?
    private let probeContext = CIContext(options: nil)
```

Add this temporary method to the class:

```swift
    /// TEMPORARY CALIBRATION PROBE — remove before shipping (plan Task 1).
    /// Logs the mean absolute difference between consecutive frame signatures so the
    /// still/change thresholds can be picked from real meetings instead of guessed.
    private func probeSignature(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = CGAffineTransform(
            scaleX: 16 / max(1, image.extent.width),
            y: 16 / max(1, image.extent.height))
        var bitmap = [UInt8](repeating: 0, count: 16 * 16 * 4)
        probeContext.render(
            image.transformed(by: scale),
            toBitmap: &bitmap,
            rowBytes: 16 * 4,
            bounds: CGRect(x: 0, y: 0, width: 16, height: 16),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        var grey = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let r = Int(bitmap[i * 4]), g = Int(bitmap[i * 4 + 1]), b = Int(bitmap[i * 4 + 2])
            grey[i] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
        }
        if let previous = probeLastSignature {
            var total = 0
            for i in 0..<256 { total += abs(Int(grey[i]) - Int(previous[i])) }
            let diff = Double(total) / (256.0 * 255.0)
            Self.log.info(
                "PROBE t=\(Int(t), privacy: .public)s diff=\(String(format: "%.4f", diff), privacy: .public)"
            )
        }
        probeLastSignature = grey
    }
```

In `handleVideoFrame`, inside the existing `Task { [weak self] in … }`, add the probe call
immediately after the `sampler.sample` line:

```swift
            let sample = await self.sampler.sample(pixelBuffer, at: elapsed)
            self.sampleQueue.sync { self.samples.append(sample) }
            self.probeSignature(pixelBuffer, at: elapsed)  // TEMPORARY (plan Task 1)
```

- [ ] **Step 2: Build the app**

Run: `./Scripts/build-app.sh`
Expected: builds and produces `build/Meeting Assistant.app`.

- [ ] **Step 3: Record two probe runs**

Run the built app and record two short meetings, watching the log with:

```sh
log stream --predicate 'subsystem == "MeetingAssistant" AND category == "capture"' --info | grep PROBE
```

- **Run A — talking heads only, ~2 minutes.** Cameras on, nobody sharing. These diffs are
  the *motion floor*: `stillThreshold` must sit **below** the minimum observed value.
- **Run B — a shared deck, ~2 minutes.** Advance a slide every ~20 s. Diffs while a slide
  is held are the *still* population; diffs at a slide flip are the *change* population.
  `changeThreshold` must sit **below** the smallest flip value.

- [ ] **Step 4: Record the measured numbers in this plan**

Append the observed ranges and the chosen constants under this task, replacing the spec's
starting values if the measurements disagree with them:

```markdown
**Calibration results (YYYY-MM-DD):**
- Run A (talking heads) diffs: min <x>, median <y>
- Run B held-slide diffs: min <x>, median <y>; slide-flip diffs: min <x>, median <y>
- Chosen: stillThreshold = <value>, changeThreshold = <value>
```

Pick `stillThreshold` roughly midway between the held-slide maximum and the talking-head
minimum, and `changeThreshold` comfortably below the smallest slide-flip diff. If the two
populations **overlap** — talking-head diffs reaching down into held-slide territory —
stop and report: the change-then-settle rule does not separate them on this hardware, and
the spec's approach C (save-then-prune-with-Vision) is the fallback that needs a decision.

- [ ] **Step 5: Revert the probe**

```bash
git checkout -- Sources/MeetingKit/CaptureSession.swift
git status --short   # expect no change to CaptureSession.swift
```

- [ ] **Step 6: Commit the calibration note**

```bash
git add docs/superpowers/plans/2026-08-20-slide-capture.md
git commit -m "docs: record slide-capture threshold calibration from real meetings"
```

---

## Task 2: `SlideChangeDetector` — the pure decision rule

**Files:**
- Create: `Sources/MeetingKit/SlideChangeDetector.swift`
- Test: `Tests/MeetingKitTests/SlideChangeDetectorTests.swift`

**Interfaces:**
- Consumes: the thresholds measured in Task 1.
- Produces:
  - `public struct FrameSignature: Equatable, Sendable` with `public let cells: [UInt8]`
    and `public init(cells: [UInt8])`.
  - `public struct SlideChangeDetector` with mutable `stillThreshold: Double`,
    `changeThreshold: Double`, `minInterval: TimeInterval`, `maxKeyframes: Int`, a
    memberwise-style `public init(stillThreshold:changeThreshold:minInterval:maxKeyframes:)`
    where every parameter defaults, and
    `public mutating func consider(_ signature: FrameSignature, at t: TimeInterval) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingKitTests/SlideChangeDetectorTests.swift`:

```swift
import Testing

@testable import MeetingKit

@Suite("SlideChangeDetector")
struct SlideChangeDetectorTests {

    /// A uniform signature of the given brightness — the simplest way to build two
    /// frames a known distance apart (diff is |a-b|/255 for uniform frames).
    private func flat(_ value: UInt8) -> FrameSignature {
        FrameSignature(cells: [UInt8](repeating: value, count: 256))
    }

    @Test("the very first sample never saves (no predecessor to prove it is still)")
    func firstSampleSkips() {
        var d = SlideChangeDetector()
        #expect(d.consider(flat(10), at: 0) == false)
    }

    @Test("a still frame that differs from the last keyframe saves")
    func stillAndDifferentSaves() {
        var d = SlideChangeDetector()
        #expect(d.consider(flat(10), at: 0) == false)  // primes `previous`
        #expect(d.consider(flat(10), at: 2.5) == true)  // still, and no keyframe yet
    }

    @Test("a still frame identical to the last keyframe does not save again")
    func stillAndSameSkips() {
        var d = SlideChangeDetector()
        _ = d.consider(flat(10), at: 0)
        #expect(d.consider(flat(10), at: 2.5) == true)
        #expect(d.consider(flat(10), at: 10) == false)  // same content → nothing new
    }

    @Test("a moving picture never saves, however different it is")
    func movingSkips() {
        var d = SlideChangeDetector()
        _ = d.consider(flat(0), at: 0)
        // Each sample is far from the previous one — a talking head, not a slide.
        #expect(d.consider(flat(120), at: 2.5) == false)
        #expect(d.consider(flat(0), at: 5) == false)
        #expect(d.consider(flat(120), at: 7.5) == false)
    }

    @Test("a new slide saves once it settles")
    func newSlideSavesWhenSettled() {
        var d = SlideChangeDetector()
        _ = d.consider(flat(10), at: 0)
        #expect(d.consider(flat(10), at: 2.5) == true)  // slide 1
        #expect(d.consider(flat(200), at: 20) == false)  // mid-flip: not still yet
        #expect(d.consider(flat(200), at: 22.5) == true)  // settled → slide 2
    }

    @Test("minInterval blocks a save that is too soon after the last one")
    func minIntervalRespected() {
        var d = SlideChangeDetector(minInterval: 5)
        _ = d.consider(flat(10), at: 0)
        #expect(d.consider(flat(10), at: 2.5) == true)  // saves at t=2.5
        _ = d.consider(flat(200), at: 3)  // flip, not still
        #expect(d.consider(flat(200), at: 4) == false)  // still + new, but only 1.5s later
        #expect(d.consider(flat(200), at: 8) == true)  // past the 5s floor
    }

    @Test("maxKeyframes caps a pathological meeting")
    func capEnforced() {
        var d = SlideChangeDetector(minInterval: 0, maxKeyframes: 2)
        var t = 0.0
        var saved = 0
        // Alternate settled content so every other sample is a fresh, still slide.
        for value: UInt8 in [10, 10, 200, 200, 10, 10, 200, 200] {
            if d.consider(flat(value), at: t) { saved += 1 }
            t += 2.5
        }
        #expect(saved == 2)
    }

    @Test("thresholds are configurable")
    func thresholdsConfigurable() {
        // A 20/255 ≈ 0.078 step counts as "still" only under a loose threshold.
        var strict = SlideChangeDetector(stillThreshold: 0.02)
        _ = strict.consider(flat(10), at: 0)
        #expect(strict.consider(flat(30), at: 2.5) == false)

        var loose = SlideChangeDetector(stillThreshold: 0.2)
        _ = loose.consider(flat(10), at: 0)
        #expect(loose.consider(flat(30), at: 2.5) == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SlideChangeDetector`
Expected: FAIL — `cannot find 'FrameSignature' in scope` / `cannot find 'SlideChangeDetector' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MeetingKit/SlideChangeDetector.swift`:

```swift
import Foundation

/// A tiny grey thumbnail of one captured frame — the only thing slide detection
/// needs to compare frames. 16×16 is enough to notice a slide change and small
/// enough that comparing two of them is free.
public struct FrameSignature: Equatable, Sendable {
    /// Row-major grey cells, 0–255.
    public let cells: [UInt8]

    public init(cells: [UInt8]) {
        self.cells = cells
    }

    /// Mean absolute difference from `other`, normalized to 0...1. Returns 1
    /// (maximally different) for mismatched sizes so a resized window can never
    /// look "still" by accident.
    func distance(to other: FrameSignature) -> Double {
        guard cells.count == other.cells.count, !cells.isEmpty else { return 1 }
        var total = 0
        for i in cells.indices {
            total += abs(Int(cells[i]) - Int(other.cells[i]))
        }
        return Double(total) / (Double(cells.count) * 255.0)
    }
}

/// Decides which captured frames are worth keeping as presentation keyframes,
/// from frame signatures alone — no Vision, no per-app knowledge.
///
/// The rule is **change-then-settle**: keep a frame when it is *holding still*
/// (barely differs from the previous sample) yet *new* (differs a lot from the last
/// frame we kept). Talking heads never hold still — webcam noise alone moves every
/// pixel between samples 2.5 s apart — while a slide, document, or dashboard holds
/// perfectly still. So "holds still" is what separates presented content from faces.
///
/// Deciding on the *current* frame rather than confirming the previous one means no
/// pixel buffer or encoded image is ever held between samples; the cost is that a
/// slide is stamped up to one sample interval after it appeared, which is irrelevant
/// for a slide that stays up for minutes.
///
/// Pure and deterministic (no I/O, no frameworks), so every branch is unit-tested.
public struct SlideChangeDetector {
    /// Distance below which consecutive samples count as "the picture is holding
    /// still". Calibrated against real meetings — see the plan's Task 1.
    public var stillThreshold: Double
    /// Distance above which a still frame counts as genuinely new content rather
    /// than the keyframe we already kept.
    public var changeThreshold: Double
    /// Floor between saved keyframes, so a flickering share can't burst.
    public var minInterval: TimeInterval
    /// Hard per-meeting cap, bounding worst-case disk use.
    public var maxKeyframes: Int

    private var previous: FrameSignature?
    private var lastKeyframe: FrameSignature?
    private var lastKeyframeTime: TimeInterval?
    private var count = 0

    public init(
        stillThreshold: Double = 0.02,
        changeThreshold: Double = 0.10,
        minInterval: TimeInterval = 5,
        maxKeyframes: Int = 300
    ) {
        self.stillThreshold = stillThreshold
        self.changeThreshold = changeThreshold
        self.minInterval = minInterval
        self.maxKeyframes = maxKeyframes
    }

    /// Whether the caller should save `signature`'s frame as a keyframe.
    /// Call once per sampled frame, in time order.
    public mutating func consider(_ signature: FrameSignature, at t: TimeInterval) -> Bool {
        defer { previous = signature }

        // No predecessor yet: we can't know the picture is still, and second-zero
        // content is as likely to be a lobby screen as a slide.
        guard let previous else { return false }
        guard count < maxKeyframes else { return false }
        guard signature.distance(to: previous) <= stillThreshold else { return false }

        if let lastKeyframeTime, t - lastKeyframeTime < minInterval { return false }
        if let lastKeyframe, signature.distance(to: lastKeyframe) < changeThreshold {
            return false
        }

        lastKeyframe = signature
        lastKeyframeTime = t
        count += 1
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SlideChangeDetector`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SlideChangeDetector.swift Tests/MeetingKitTests/SlideChangeDetectorTests.swift
git commit -m "feat: add pure slide-change detector (change-then-settle rule)"
```

---

## Task 3: `SlideKeyframe` model and back-compatible `MeetingRecording`

**Files:**
- Modify: `Sources/MeetingKit/Models.swift`
- Test: `Tests/MeetingKitTests/SlideKeyframeDecodingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SlideKeyframe: Codable, Sendable, Equatable` with
    `public let timestamp: TimeInterval`, `public let file: String`, and
    `public init(timestamp:file:)`.
  - `MeetingRecording.slides: [SlideKeyframe]`, plus a `slides:` parameter **defaulted to
    `[]`** on its existing `init` so all current call sites compile unchanged.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingKitTests/SlideKeyframeDecodingTests.swift`:

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("SlideKeyframe + MeetingRecording decoding")
struct SlideKeyframeDecodingTests {

    private func meeting() -> Meeting {
        Meeting(
            id: "m1", title: "Sync", startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 1800), provider: nil, joinURL: nil)
    }

    @Test("a recording.json written before slides existed decodes with no slides")
    func legacyRecordingDecodes() throws {
        // Exactly the shape written before this feature: no `slides` key at all.
        let json = """
            {
              "meeting": {
                "id": "m1", "title": "Sync",
                "startDate": "1970-01-01T00:00:00Z", "endDate": "1970-01-01T00:30:00Z"
              },
              "recordedAt": "1970-01-01T00:00:00Z",
              "micAudioFile": "mic.wav",
              "systemAudioFile": "system.wav",
              "timeline": { "samples": [] }
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(MeetingRecording.self, from: Data(json.utf8))
        #expect(rec.slides.isEmpty)
        #expect(rec.micAudioFile == "mic.wav")
    }

    @Test("slides round-trip through encode and decode")
    func slidesRoundTrip() throws {
        let rec = MeetingRecording(
            meeting: meeting(), recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: []),
            slides: [
                SlideKeyframe(timestamp: 391, file: "slides/slide-0391.jpg"),
                SlideKeyframe(timestamp: 512, file: "slides/slide-0512.jpg"),
            ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(MeetingRecording.self, from: try encoder.encode(rec))
        #expect(back.slides.count == 2)
        #expect(back.slides[0].file == "slides/slide-0391.jpg")
        #expect(back.slides[1].timestamp == 512)
    }

    @Test("omitting slides at the call site keeps existing callers working")
    func slidesDefaultToEmpty() {
        let rec = MeetingRecording(
            meeting: meeting(), recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: []))
        #expect(rec.slides.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "SlideKeyframe"`
Expected: FAIL — `cannot find 'SlideKeyframe' in scope`.

- [ ] **Step 3: Add the model**

In `Sources/MeetingKit/Models.swift`, immediately **above** `struct MeetingRecording`, add:

```swift
/// One saved picture of a shared screen, produced during capture by `SlideRecorder`
/// whenever the presented content materially changed.
public struct SlideKeyframe: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval  // seconds from meeting start
    public let file: String  // bundle-relative path, e.g. "slides/slide-0391.jpg"

    public init(timestamp: TimeInterval, file: String) {
        self.timestamp = timestamp
        self.file = file
    }
}
```

- [ ] **Step 4: Add `slides` to `MeetingRecording`**

In the same file, replace the `MeetingRecording` declaration through the end of its `init`
with:

```swift
/// Metadata persisted alongside a captured meeting's audio + timeline on disk.
public struct MeetingRecording: Codable, Sendable, Equatable {
    public let meeting: Meeting
    public let recordedAt: Date
    public let micAudioFile: String  // filename within the bundle
    public let systemAudioFile: String
    public let timeline: SpeakerTimeline
    /// Pictures of a shared screen captured during the meeting, oldest first.
    /// Empty for meetings with no presentation — and for every recording saved
    /// before slide capture existed (see `init(from:)`).
    public let slides: [SlideKeyframe]

    public init(
        meeting: Meeting,
        recordedAt: Date,
        micAudioFile: String,
        systemAudioFile: String,
        timeline: SpeakerTimeline,
        slides: [SlideKeyframe] = []
    ) {
        self.meeting = meeting
        self.recordedAt = recordedAt
        self.micAudioFile = micAudioFile
        self.systemAudioFile = systemAudioFile
        self.timeline = timeline
        self.slides = slides
    }

    /// Hand-written so `slides` can be absent: every `recording.json` written before
    /// slide capture existed lacks the key, and the synthesized decoder would reject
    /// those files outright — losing the user's entire history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meeting = try c.decode(Meeting.self, forKey: .meeting)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        micAudioFile = try c.decode(String.self, forKey: .micAudioFile)
        systemAudioFile = try c.decode(String.self, forKey: .systemAudioFile)
        timeline = try c.decode(SpeakerTimeline.self, forKey: .timeline)
        slides = try c.decodeIfPresent([SlideKeyframe].self, forKey: .slides) ?? []
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "SlideKeyframe"`
Expected: PASS, 3 tests.

- [ ] **Step 6: Run the whole suite for regressions**

Run: `swift test`
Expected: PASS. (Existing `MeetingRecording(...)` call sites still compile because
`slides` defaults.)

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingKit/Models.swift Tests/MeetingKitTests/SlideKeyframeDecodingTests.swift
git commit -m "feat: add SlideKeyframe model with back-compatible recording decode"
```

---

## Task 4: `SlideRecorder` — signature, decide, write

**Files:**
- Create: `Sources/MeetingKit/SlideRecorder.swift`

**Interfaces:**
- Consumes: `FrameSignature`, `SlideChangeDetector` (Task 2); `SlideKeyframe` (Task 3).
- Produces: `public actor SlideRecorder` with
  `public init(directory: URL, detector: SlideChangeDetector = .init(), fileManager: FileManager = .default)`,
  `public func consider(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval)`, and
  `public func keyframes() -> [SlideKeyframe]`. `directory` is the **meeting bundle**
  directory; the recorder creates `slides/` inside it on first save.

No unit tests: this touches CoreImage and the filesystem with real pixel buffers, which is
the integration category the project verifies by running (N8). All the logic worth testing
lives in Task 2's detector.

- [ ] **Step 1: Write the implementation**

Create `Sources/MeetingKit/SlideRecorder.swift`:

```swift
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO  // kCGImageDestinationLossyCompressionQuality
import os

/// Saves pictures of a shared screen during a meeting: reduces each sampled frame to
/// a `FrameSignature`, asks `SlideChangeDetector` whether it is a new slide, and writes
/// a JPEG when it is.
///
/// An `actor` for two reasons. First, the detector's rule depends on frames arriving in
/// **time order**, and actor isolation serializes `consider` calls without a lock.
/// Second — and this is the load-bearing one — `CaptureSession`'s `outputQueue` is a
/// *serial* queue shared by the system-audio and screen-frame handlers, so CoreImage and
/// file work must never run on it: ScreenCaptureKit sheds samples when a client's handler
/// queue backs up, and because `system.wav` is written by appending buffers with no
/// timestamps, shed samples silently shorten the file and shift every later word earlier.
/// Calls therefore arrive from the `Task` that `handleVideoFrame` already spawns.
///
/// Best-effort throughout (N3): an unreadable frame or a failed write is logged and
/// dropped. Nothing here can fail a recording.
public actor SlideRecorder {
    /// Cells per side of the grey signature (16×16 = 256 cells).
    private static let signatureSide = 16
    private static let log = Logger(subsystem: "MeetingAssistant", category: "slides")

    private let bundleDirectory: URL
    private let fileManager: FileManager
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var detector: SlideChangeDetector
    private var saved: [SlideKeyframe] = []
    private var didCreateDirectory = false

    public init(
        directory: URL,
        detector: SlideChangeDetector = .init(),
        fileManager: FileManager = .default
    ) {
        self.bundleDirectory = directory
        self.detector = detector
        self.fileManager = fileManager
    }

    /// Consider one sampled frame; writes a keyframe if it looks like new, settled
    /// presentation content. Call in time order, once per sampled frame.
    public func consider(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        guard let signature = signature(of: pixelBuffer) else { return }
        guard detector.consider(signature, at: t) else { return }
        write(pixelBuffer, at: t)
    }

    /// Every keyframe written so far, oldest first. Read once at `stop()`.
    public func keyframes() -> [SlideKeyframe] {
        saved
    }

    // MARK: - Signature

    /// Downscale the frame to a 16×16 grey thumbnail. One small GPU render per sampled
    /// frame — the whole cost of slide detection.
    private func signature(of pixelBuffer: CVPixelBuffer) -> FrameSignature? {
        let side = Self.signatureSide
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let scaled = image.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(side) / image.extent.width,
                y: CGFloat(side) / image.extent.height))

        var bitmap = [UInt8](repeating: 0, count: side * side * 4)
        context.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: side * 4,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())

        // Rec. 601 luma: cheap, and matches how "brightness changed" reads to a viewer.
        var cells = [UInt8](repeating: 0, count: side * side)
        for i in 0..<(side * side) {
            let r = Int(bitmap[i * 4]), g = Int(bitmap[i * 4 + 1]), b = Int(bitmap[i * 4 + 2])
            cells[i] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
        }
        return FrameSignature(cells: cells)
    }

    // MARK: - Writing

    /// Encode the frame as JPEG and append it to the manifest. Named by whole-second
    /// offset, so filenames are deterministic and sort chronologically; the 5 s
    /// `minInterval` makes collisions impossible.
    private func write(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        let name = String(format: "slide-%04d.jpg", Int(t))
        let relativePath = "slides/\(name)"
        let directory = bundleDirectory.appendingPathComponent("slides", isDirectory: true)

        if !didCreateDirectory {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                didCreateDirectory = true
            } catch {
                Self.log.error(
                    "Couldn't create the slides directory: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard
            let data = context.jpegRepresentation(
                of: image,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
            )
        else {
            Self.log.error("Couldn't encode a slide keyframe as JPEG.")
            return
        }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            saved.append(SlideKeyframe(timestamp: t, file: relativePath))
        } catch {
            Self.log.error(
                "Couldn't write \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors or warnings.

- [ ] **Step 3: Run the suite**

Run: `swift test`
Expected: PASS (nothing new is tested here; this confirms nothing broke).

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingKit/SlideRecorder.swift
git commit -m "feat: add SlideRecorder to write shared-screen keyframes off the capture queue"
```

---

## Task 5: Wire the recorder into `CaptureSession`

**Files:**
- Modify: `Sources/MeetingKit/CaptureSession.swift`

**Interfaces:**
- Consumes: `SlideRecorder` (Task 4), `SlideKeyframe` (Task 3).
- Produces: `CaptureSession.capturesSlides: Bool` (public, default `true`), read by
  `AppState` in Task 9.

**Critical:** all slide work goes inside the `Task` that `handleVideoFrame` already
spawns. Nothing is added to the synchronous body of `handleVideoFrame`, which runs on the
serial `outputQueue` shared with system-audio delivery.

- [ ] **Step 1: Add the flag and the recorder property**

In `Sources/MeetingKit/CaptureSession.swift`, directly below the existing
`public var frameSampleInterval: TimeInterval = 2.5`, add:

```swift
    /// Whether to save pictures of a shared screen when someone presents (R28).
    /// Set from Settings before `start()`; on by default.
    public var capturesSlides: Bool = true
```

Below `private let sampler: SpeakerSampler`, add:

```swift
    /// Writes shared-screen keyframes. Nil when slide capture is off (R28) — and it
    /// stays nil for the whole session, so the flag can't change mid-meeting.
    private var slideRecorder: SlideRecorder?
```

- [ ] **Step 2: Create the recorder in `start()`**

In `start()`, replace the body with:

```swift
    public func start() async throws {
        let dir = try store.directory(for: meeting.id)

        if capturesSlides {
            slideRecorder = SlideRecorder(directory: dir)
        }
        try startMicrophoneCapture(into: dir.appendingPathComponent("mic.wav"))
        try await startSystemCapture(systemAudioURL: dir.appendingPathComponent("system.wav"))
    }
```

- [ ] **Step 3: Feed frames to the recorder**

In `handleVideoFrame`, replace the existing `Task` block with:

```swift
        // Run the (best-effort) speaker read and slide capture off the capture queue.
        // `outputQueue` is serial and shared with system-audio delivery, so CoreImage
        // and file work must never happen in the handler itself — a backed-up handler
        // queue makes ScreenCaptureKit shed audio samples, which silently shortens
        // system.wav and shifts every later timestamp.
        Task { [weak self] in
            guard let self else { return }
            let sample = await self.sampler.sample(pixelBuffer, at: elapsed)
            self.sampleQueue.sync { self.samples.append(sample) }
            await self.slideRecorder?.consider(pixelBuffer, at: elapsed)
        }
```

- [ ] **Step 4: Save the manifest in `stop()`**

In `stop()`, replace the `MeetingRecording` construction with:

```swift
        let timeline = SpeakerTimeline(samples: sampleQueue.sync { samples })
        let slides = await slideRecorder?.keyframes() ?? []
        let recording = MeetingRecording(
            meeting: meeting,
            recordedAt: startWallClock,
            micAudioFile: "mic.wav",
            systemAudioFile: "system.wav",
            timeline: timeline,
            slides: slides
        )
        try store.save(recording)
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: PASS, including `CaptureSessionConvertTests`, `CaptureSizeTests`, and
`CaptureSessionAudioFileTests`.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingKit/CaptureSession.swift
git commit -m "feat: capture shared-screen keyframes during a meeting"
```

---

## Task 6: `TranscriptFormatter` writes slide lines

**Files:**
- Modify: `Sources/MeetingKit/TranscriptFormatter.swift`
- Test: `Tests/MeetingKitTests/SlideTranscriptTests.swift` (created here; extended in Task 7)

**Interfaces:**
- Consumes: `SlideKeyframe` (Task 3).
- Produces: `TranscriptFormatter.transcriptBody(_:baseDate:timeZone:slides:)` and
  `TranscriptFormatter.document(meeting:segments:baseDate:note:slides:)`, both with
  `slides: [SlideKeyframe] = []` as the **last** parameter.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MeetingKitTests/SlideTranscriptTests.swift`:

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("Slides in the transcript")
struct SlideTranscriptTests {

    private func segment(_ start: TimeInterval, _ speaker: String, _ text: String)
        -> LabeledSegment
    {
        LabeledSegment(start: start, end: start + 5, text: text, speaker: speaker)
    }

    private var base: Date { Date(timeIntervalSince1970: 0) }

    @Test("no slides reproduces today's output exactly")
    func emptySlidesUnchanged() {
        let segs = [segment(0, "Me", "hello"), segment(10, "Ada", "hi")]
        let withArg = TranscriptFormatter.transcriptBody(segs, baseDate: base, slides: [])
        let without = TranscriptFormatter.transcriptBody(segs, baseDate: base)
        #expect(withArg == without)
    }

    @Test("a slide is written after the last turn that started before it")
    func slideInterleaved() {
        let segs = [segment(0, "Me", "hello"), segment(60, "Ada", "hi")]
        let body = TranscriptFormatter.transcriptBody(
            segs, baseDate: base,
            slides: [SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg")])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("hello"))
        #expect(lines[1] == "![Shared screen 00:00:30](slides/slide-0030.jpg)")
        #expect(lines[2].contains("hi"))
    }

    @Test("a slide before any speech leads the body")
    func slideBeforeFirstTurn() {
        let body = TranscriptFormatter.transcriptBody(
            [segment(60, "Ada", "hi")], baseDate: base,
            slides: [SlideKeyframe(timestamp: 5, file: "slides/slide-0005.jpg")])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines[0] == "![Shared screen 00:00:05](slides/slide-0005.jpg)")
        #expect(lines[1].contains("hi"))
    }

    @Test("a slide after all speech trails the body")
    func slideAfterLastTurn() {
        let body = TranscriptFormatter.transcriptBody(
            [segment(0, "Me", "hello")], baseDate: base,
            slides: [SlideKeyframe(timestamp: 600, file: "slides/slide-0600.jpg")])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[1] == "![Shared screen 00:10:00](slides/slide-0600.jpg)")
    }

    @Test("several slides between two turns keep their order")
    func multipleSlidesOrdered() {
        let body = TranscriptFormatter.transcriptBody(
            [segment(0, "Me", "hello"), segment(600, "Ada", "hi")], baseDate: base,
            slides: [
                SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg"),
                SlideKeyframe(timestamp: 90, file: "slides/slide-0090.jpg"),
            ])
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines[1].contains("slide-0030.jpg"))
        #expect(lines[2].contains("slide-0090.jpg"))
    }

    @Test("document() carries slides into the rendered document")
    func documentIncludesSlides() {
        let meeting = Meeting(
            id: "m1", title: "Sync", startDate: base, endDate: base.addingTimeInterval(1800),
            provider: nil, joinURL: nil)
        let doc = TranscriptFormatter.document(
            meeting: meeting, segments: [segment(0, "Me", "hello")], baseDate: base,
            note: nil, slides: [SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg")])
        #expect(doc.contains("![Shared screen 00:00:30](slides/slide-0030.jpg)"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "Slides in the transcript"`
Expected: FAIL — no `slides:` parameter on `transcriptBody`/`document`.

- [ ] **Step 3: Implement the interleaving**

In `Sources/MeetingKit/TranscriptFormatter.swift`, replace `transcriptBody` with:

```swift
    /// Build the transcript body: one line per speaker turn, prefixed with a
    /// timestamp. With `baseDate` set, the timestamp is the **real wall-clock
    /// time** (`HH:mm:ss`) of when each turn was spoken (baseDate + offset);
    /// without it, an elapsed `[mm:ss]` offset.
    ///
    /// `slides` (R28) are written in as Markdown image lines, each after the last turn
    /// that started before it — so the reader meets a slide where it appeared in the
    /// conversation. Real Markdown, so an exported transcript renders the images in any
    /// viewer that has the `slides/` folder beside it, and degrades to the alt text
    /// where it doesn't.
    public static func transcriptBody(
        _ segments: [LabeledSegment],
        baseDate: Date? = nil,
        timeZone: TimeZone = .current,
        slides: [SlideKeyframe] = []
    ) -> String {
        guard !segments.isEmpty || !slides.isEmpty else { return "" }

        var turns: [(start: TimeInterval, speaker: String, text: String)] = []
        for seg in segments {
            if var last = turns.last, last.speaker == seg.speaker {
                last.text += " " + seg.text
                turns[turns.count - 1] = last
            } else {
                turns.append((seg.start, seg.speaker, seg.text))
            }
        }

        func slideLine(_ slide: SlideKeyframe) -> String {
            let stamp = timestamp(slide.timestamp, baseDate: baseDate, timeZone: timeZone)
            return "![Shared screen \(stamp)](\(slide.file))"
        }

        let ordered = slides.sorted { $0.timestamp < $1.timestamp }
        var lines: [String] = []
        var pending = ordered[...]

        for turn in turns {
            // Slides that appeared before this turn started belong above it.
            while let next = pending.first, next.timestamp < turn.start {
                lines.append(slideLine(next))
                pending = pending.dropFirst()
            }
            lines.append(
                "**[\(timestamp(turn.start, baseDate: baseDate, timeZone: timeZone))] \(turn.speaker):** \(turn.text)"
            )
        }
        // Anything left appeared after the last turn began.
        for slide in pending { lines.append(slideLine(slide)) }

        return lines.joined(separator: "\n")
    }
```

Then replace `document` with:

```swift
    /// A full meeting document: title + recording time header, an optional note
    /// line, then the transcript with real wall-clock timestamps.
    public static func document(
        meeting: Meeting,
        segments: [LabeledSegment],
        baseDate: Date? = nil,
        note: String? = nil,
        slides: [SlideKeyframe] = []
    ) -> String {
        let start = baseDate ?? meeting.startDate
        let date = ISO8601DateFormatter().string(from: start)
        let noteLine = note.map { "\n_\($0)_\n" } ?? ""
        return
            "# \(meeting.title)\n\(date)\n\(noteLine)\n\(transcriptBody(segments, baseDate: start, slides: slides))\n"
    }
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter "Slides in the transcript"`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the existing formatter tests for regressions**

Run: `swift test --filter TranscriptFormatter`
Expected: PASS — the `slides` parameter defaults, and a turn line's format is untouched.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/TranscriptFormatter.swift Tests/MeetingKitTests/SlideTranscriptTests.swift
git commit -m "feat: write shared-screen keyframes into the transcript"
```

---

## Task 7: `TranscriptParser` recovers slides without touching `turns`

**Files:**
- Modify: `Sources/MeetingKit/TranscriptParser.swift`
- Test: `Tests/MeetingKitTests/SlideTranscriptTests.swift` (extend)

**Interfaces:**
- Consumes: the line format from Task 6 (`![Shared screen HH:mm:ss](slides/slide-NNNN.jpg)`).
- Produces: `TranscriptParser.Slide` (`public let time: String`, `public let file: String`,
  `public let afterTurnIndex: Int`) and `TranscriptParser.Parsed.slides: [Slide]`, plus a
  `slides:` parameter on `Parsed.init` **defaulted to `[]`**.

**Why `turns` must not change:** `TranscriptAudioLocator.locate` gates on
`groups?.count == turns.count` (`Sources/MeetingKit/TranscriptAudioLocator.swift:78`) and
matches parsed turns **positionally** against groups from `segments.json`. Parsing slide
lines into `turns` would break that equality and silently downgrade every line in the
meeting from an exact clip to a stamp-derived window — a quiet R27 regression.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MeetingKitTests/SlideTranscriptTests.swift`, inside the `@Suite` struct:

```swift
    // MARK: - Parsing back

    private var documentWithSlide: String {
        """
        # Sync
        1970-01-01T00:00:00Z

        **[00:00:00] Me:** hello
        ![Shared screen 00:00:30](slides/slide-0030.jpg)
        **[00:10:00] Ada:** hi
        """
    }

    @Test("a slide line is parsed into slides, not turns")
    func slideParsedSeparately() {
        let parsed = TranscriptParser.parse(documentWithSlide)
        #expect(parsed.turns.count == 2)
        #expect(parsed.slides.count == 1)
        #expect(parsed.slides[0].file == "slides/slide-0030.jpg")
        #expect(parsed.slides[0].time == "00:00:30")
        #expect(parsed.slides[0].afterTurnIndex == 0)
    }

    @Test("turns are identical with and without slide lines (R27 playback can't regress)")
    func turnsUnaffectedBySlides() {
        let withoutSlide = documentWithSlide
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("![") }
            .joined(separator: "\n")
        #expect(TranscriptParser.parse(documentWithSlide).turns
            == TranscriptParser.parse(withoutSlide).turns)
    }

    @Test("a slide before the first turn gets index -1")
    func slideBeforeFirstTurnParsed() {
        let doc = """
            # Sync
            1970-01-01T00:00:00Z

            ![Shared screen 00:00:05](slides/slide-0005.jpg)
            **[00:01:00] Ada:** hi
            """
        let parsed = TranscriptParser.parse(doc)
        #expect(parsed.slides.count == 1)
        #expect(parsed.slides[0].afterTurnIndex == -1)
        #expect(parsed.turns.count == 1)
        #expect(parsed.title == "Sync")  // the slide line didn't eat the header
    }

    @Test("a malformed image line doesn't corrupt the preceding turn")
    func malformedImageLineIgnored() {
        let doc = """
            **[00:00:00] Me:** hello
            ![Shared screen 00:00:30
            """
        let parsed = TranscriptParser.parse(doc)
        #expect(parsed.slides.isEmpty)
        #expect(parsed.turns.count == 1)
        // It falls through to the stray-line rule, which appends it to the last turn —
        // ugly but lossless, and it never fabricates a slide.
        #expect(parsed.turns[0].text.hasPrefix("hello"))
    }

    @Test("a formatted document round-trips through the parser")
    func roundTrip() {
        let meeting = Meeting(
            id: "m1", title: "Sync", startDate: base, endDate: base.addingTimeInterval(1800),
            provider: nil, joinURL: nil)
        let doc = TranscriptFormatter.document(
            meeting: meeting,
            segments: [segment(0, "Me", "hello"), segment(600, "Ada", "hi")],
            baseDate: base, note: nil,
            slides: [SlideKeyframe(timestamp: 30, file: "slides/slide-0030.jpg")])
        let parsed = TranscriptParser.parse(doc)
        #expect(parsed.turns.count == 2)
        #expect(parsed.slides.count == 1)
        #expect(parsed.slides[0].afterTurnIndex == 0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "Slides in the transcript"`
Expected: FAIL — `value of type 'Parsed' has no member 'slides'`.

- [ ] **Step 3: Add the `Slide` type and `Parsed.slides`**

In `Sources/MeetingKit/TranscriptParser.swift`, add after the `Turn` struct:

```swift
    /// A shared-screen keyframe recovered from the document (R28). Kept **separate**
    /// from `turns` on purpose: `TranscriptAudioLocator` matches turns positionally
    /// against `segments.json`, so adding non-speech entries to `turns` would silently
    /// break per-line audio playback (R27).
    public struct Slide: Equatable, Sendable {
        public let time: String  // "00:00:30", as written in the document
        public let file: String  // bundle-relative, e.g. "slides/slide-0030.jpg"
        /// Index of the turn this slide follows; `-1` when it precedes all speech.
        public let afterTurnIndex: Int
        public init(time: String, file: String, afterTurnIndex: Int) {
            self.time = time
            self.file = file
            self.afterTurnIndex = afterTurnIndex
        }
    }
```

Replace the `Parsed` struct with:

```swift
    public struct Parsed: Equatable, Sendable {
        public let title: String?
        public let note: String?
        public let turns: [Turn]
        public let slides: [Slide]
        public init(title: String?, note: String?, turns: [Turn], slides: [Slide] = []) {
            self.title = title
            self.note = note
            self.turns = turns
            self.slides = slides
        }
    }
```

- [ ] **Step 4: Parse the image lines**

In `parse`, add `var slides: [Slide] = []` beside the other accumulators, then insert the
slide branch **immediately after** the `if let turn = parseTurn(line)` block — above the
`if turns.isEmpty` header region, so a leading slide isn't mistaken for a title, and above
the stray-line fallback, which would otherwise append the image line into the previous
turn's prose:

```swift
            if let slide = parseSlide(line, afterTurnIndex: turns.count - 1) {
                slides.append(slide)
                continue
            }
```

Update the return to `Parsed(title: title, note: note, turns: turns, slides: slides)`.

Then add this method beside `parseTurn`:

```swift
    /// Parse `![<alt>](<path>)`; nil if `line` isn't a well-formed image line. The alt
    /// text's trailing token is the timestamp the formatter wrote
    /// ("Shared screen 00:00:30").
    private static func parseSlide(_ line: String, afterTurnIndex: Int) -> Slide? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
            let altEnd = line.range(of: "](")
        else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let path = String(line[altEnd.upperBound..<line.index(before: line.endIndex)])
        guard !path.isEmpty else { return nil }
        let time = alt.split(separator: " ").last.map(String.init) ?? ""
        return Slide(time: time, file: path, afterTurnIndex: afterTurnIndex)
    }
```

`Slide` is declared as a sibling of `Turn` inside `enum TranscriptParser` (Step 3), so it
is spelled `Slide` unqualified within the enum and `TranscriptParser.Slide` from outside
(as Task 10 does) — **not** `Parsed.Slide`.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "Slides in the transcript"`
Expected: PASS, 11 tests.

- [ ] **Step 6: Run the parser and locator suites for regressions**

Run: `swift test --filter "TranscriptParser"` then `swift test --filter "TranscriptAudioLocator"`
Expected: PASS both. If `Parsed(...)` construction fails to compile anywhere, the
defaulted `slides:` parameter is missing — fix that rather than changing call sites.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingKit/TranscriptParser.swift Tests/MeetingKitTests/SlideTranscriptTests.swift
git commit -m "feat: parse shared-screen keyframes out of the transcript document"
```

---

## Task 8: `MeetingProcessor` passes slides to the formatter

**Files:**
- Modify: `Sources/MeetingKit/MeetingProcessor.swift`

**Interfaces:**
- Consumes: `MeetingRecording.slides` (Task 3), `document(…slides:)` (Task 6).
- Produces: nothing new.

- [ ] **Step 1: Pass the slides through**

In `Sources/MeetingKit/MeetingProcessor.swift`, in step 3 of `process`, replace the
`TranscriptFormatter.document` call with:

```swift
        let transcript = TranscriptFormatter.document(
            meeting: recording.meeting,
            segments: labeled,
            baseDate: recording.recordedAt,
            note: note,
            slides: recording.slides
        )
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Run the suite**

Run: `swift test`
Expected: PASS, including the `MeetingProcessor*` suites.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingKit/MeetingProcessor.swift
git commit -m "feat: render captured slides into the saved transcript"
```

---

## Task 9: Store accessor, setting, and capture wiring

**Files:**
- Modify: `Sources/MeetingKit/MeetingStore.swift`
- Modify: `Sources/MeetingAssistant/Settings.swift`
- Modify: `Sources/MeetingAssistant/SettingsView.swift`
- Modify: `Sources/MeetingAssistant/AppState.swift`
- Test: `Tests/MeetingKitTests/MeetingStoreSlidesTests.swift`

**Interfaces:**
- Consumes: `CaptureSession.capturesSlides` (Task 5).
- Produces:
  - `MeetingStore.slidesDirectory(for meetingID: String) -> URL` — non-creating.
  - `AppSettings.captureSlides: Bool` and `AppSettings.Keys.captureSlides`.
  - `AppState.slidesDirectory(for recording: MeetingRecording) -> URL` — used by Task 10.

The spec relies on slide retention needing **no** store code: `expireMedia` removes only
the two `.wav` files, so slides survive audio expiry (the retention choice the owner made),
and the directory walkers already count them. That's a property worth locking down with a
test rather than trusting — hence Steps 1–3 below.

- [ ] **Step 1: Write the failing retention test**

Create `Tests/MeetingKitTests/MeetingStoreSlidesTests.swift`:

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingStore slides")
struct MeetingStoreSlidesTests {

    /// A store rooted in a fresh temp directory, isolated per test.
    private func makeTempStore() throws -> MeetingStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "MeetingStoreSlidesTests-\(UUID().uuidString)", isDirectory: true)
        return try MeetingStore(root: tmp)
    }

    /// Write a bundle with both WAVs and one slide image.
    private func seed(_ store: MeetingStore, id: String) throws -> URL {
        let dir = try store.directory(for: id)
        try Data("mic".utf8).write(to: dir.appendingPathComponent("mic.wav"))
        try Data("sys".utf8).write(to: dir.appendingPathComponent("system.wav"))
        let slides = dir.appendingPathComponent("slides", isDirectory: true)
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        try Data("jpegbytes".utf8).write(to: slides.appendingPathComponent("slide-0030.jpg"))
        return dir
    }

    @Test("expiring audio keeps the captured slides (they follow the transcript, R26)")
    func expireMediaKeepsSlides() throws {
        let store = try makeTempStore()
        let dir = try seed(store, id: "m1")
        store.expireMedia(meetingID: "m1")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path) == false)
        #expect(
            fm.fileExists(
                atPath: dir.appendingPathComponent("slides/slide-0030.jpg").path) == true)
    }

    @Test("slide bytes count toward the bundle size shown in Storage")
    func slidesCountedInSize() throws {
        let store = try makeTempStore()
        _ = try seed(store, id: "m1")
        let withSlides = store.bundleSize(meetingID: "m1")
        store.expireMedia(meetingID: "m1")
        let slidesOnly = store.bundleSize(meetingID: "m1")
        #expect(slidesOnly > 0)  // the slide image is still counted after audio expiry
        #expect(withSlides > slidesOnly)
    }

    @Test("slidesDirectory points into the bundle without creating it")
    func slidesDirectoryDoesNotCreate() throws {
        let store = try makeTempStore()
        let url = store.slidesDirectory(for: "never-recorded")
        #expect(url.lastPathComponent == "slides")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        // And it must not have resurrected the bundle directory either.
        #expect(
            FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) == false)
    }

    @Test("deleting a meeting removes its slides too")
    func deleteRemovesSlides() throws {
        let store = try makeTempStore()
        let dir = try seed(store, id: "m1")
        try store.delete(meetingID: "m1")
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "MeetingStore slides"`
Expected: FAIL — `value of type 'MeetingStore' has no member 'slidesDirectory'`. (The
`expireMedia` and `delete` tests should already pass; they exist to lock in behavior the
spec depends on.)

- [ ] **Step 3: Add the non-creating store accessor**

In `Sources/MeetingKit/MeetingStore.swift`, directly after `transcriptURL(for:)`, add:

```swift
    /// On-disk location of a meeting's captured slide images (may not exist). Uses the
    /// non-creating path deliberately: `directory(for:)` creates on demand and would
    /// resurrect a deleted bundle as an empty folder.
    public func slidesDirectory(for meetingID: String) -> URL {
        bundleURL(for: meetingID).appendingPathComponent("slides", isDirectory: true)
    }
```

Move the `bundleURL(for:)` declaration above this method if the compiler complains about
ordering — it is `private` and declared under "Retention helpers"; Swift does not require
reordering, so no change should be needed.

- [ ] **Step 4: Add the preference**

In `Sources/MeetingAssistant/Settings.swift`, add after `identifyInRoomSpeakers`:

```swift
    /// Whether to save pictures of a shared screen when someone presents (R28). On by
    /// default — the app should just do it — with this toggle for meetings where a
    /// customer's screen shouldn't be kept on disk.
    @Published var captureSlides: Bool {
        didSet { defaults.set(captureSlides, forKey: Keys.captureSlides) }
    }
```

Add to `enum Keys`:

```swift
        static let captureSlides = "captureSlides"
```

And in `init`, after the `identifyInRoomSpeakers` line:

```swift
        // Default ON the first time (key absent); respect the user's choice after.
        self.captureSlides =
            defaults.object(forKey: Keys.captureSlides) == nil
            ? true
            : defaults.bool(forKey: Keys.captureSlides)
```

- [ ] **Step 5: Add the Settings toggle**

In `Sources/MeetingAssistant/SettingsView.swift`, in `generalTab`, add a second `Section`
after the existing Dock-icon one (inside the same `Form`):

```swift
            Section {
                Toggle(
                    "Capture shared screens",
                    isOn: Binding(
                        get: { state.settings.captureSlides },
                        set: { state.settings.captureSlides = $0 }
                    )
                )
            } footer: {
                Text(
                    "Saves a picture whenever a presented screen changes, shown in the "
                        + "transcript where it appeared. Kept as long as the transcript, "
                        + "and only the meeting window is ever captured."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 6: Wire the setting into capture and expose the directory**

In `Sources/MeetingAssistant/AppState.swift`, in `startCapture(for:)`, replace the session
construction with:

```swift
        let session = CaptureSession(meeting: meeting, store: store)
        // R28: read once at start, so toggling Settings mid-meeting can't change
        // what this recording captures halfway through.
        session.capturesSlides = settings.captureSlides
```

Then add beside `audioDirectory(for:)`:

```swift
    /// Directory holding a meeting's captured slide images. Unlike the audio
    /// directory this stays valid after audio expires — slides are kept as long as
    /// the transcript (R26).
    func slidesDirectory(for recording: MeetingRecording) -> URL {
        store.slidesDirectory(for: recording.meeting.id)
    }
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 8: Run the new suite, then the whole suite**

Run: `swift test --filter "MeetingStore slides"`
Expected: PASS, 4 tests.

Run: `swift test`
Expected: PASS, including `MeetingStoreTests` and `MeetingStoreRetentionTests`.

- [ ] **Step 9: Verify the toggle by running the app**

Run: `./Scripts/build-app.sh --run`
Confirm: Settings → General shows "Capture shared screens", on by default, and the choice
survives quitting and relaunching the app.

- [ ] **Step 10: Commit**

```bash
git add Sources/MeetingKit/MeetingStore.swift Tests/MeetingKitTests/MeetingStoreSlidesTests.swift Sources/MeetingAssistant/Settings.swift Sources/MeetingAssistant/SettingsView.swift Sources/MeetingAssistant/AppState.swift
git commit -m "feat: add the capture-shared-screens setting and wire it into capture"
```

---

## Task 10: Render slides inline in the reading view

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

**Interfaces:**
- Consumes: `TranscriptParser.Parsed.slides` (Task 7), `AppState.slidesDirectory(for:)`
  (Task 9).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Accept a slides directory in the reading view**

In `Sources/MeetingAssistant/MainWindowView.swift`, in `TranscriptReadingView`, add below
`var playback: Playback? = nil`:

```swift
    /// Where this meeting's captured slide images live (R28). Separate from
    /// `playback` on purpose: slides outlive the audio, so they must still render
    /// once `playback` is nil after audio expiry.
    var slidesDirectory: URL? = nil
```

- [ ] **Step 2: Render slides between turns**

In the same view's `body`, replace the `ForEach` over turns with:

```swift
                    // A slide with afterTurnIndex == -1 appeared before any speech.
                    ForEach(parsed.slides.filter { $0.afterTurnIndex < 0 }, id: \.file) { slide in
                        SlideImageView(slide: slide, directory: slidesDirectory)
                            .padding(.bottom, Theme.Space.m)
                    }
                    ForEach(Array(parsed.turns.enumerated()), id: \.offset) { index, turn in
                        TurnView(
                            turn: turn, localUserName: localUserName, index: index,
                            clip: clips[index], playback: playback
                        )
                        .padding(.bottom, Theme.Space.m)
                        ForEach(parsed.slides.filter { $0.afterTurnIndex == index }, id: \.file) {
                            slide in
                            SlideImageView(slide: slide, directory: slidesDirectory)
                                .padding(.bottom, Theme.Space.m)
                        }
                    }
```

- [ ] **Step 3: Add the slide view**

Add this private view immediately after the `TurnView` struct:

```swift
/// One captured shared screen, shown where it appeared in the conversation (R28).
/// Clicking opens the file in Preview — the native way to zoom, with no window
/// plumbing of our own. Renders nothing if the file is missing (a hand-deleted
/// image, or a transcript exported away from its bundle), so a gap never becomes
/// an error.
private struct SlideImageView: View {
    let slide: TranscriptParser.Slide
    let directory: URL?

    /// `slide.file` is bundle-relative ("slides/slide-0030.jpg") while `directory`
    /// already points at `slides/`, so resolve against the bundle root.
    private var url: URL? {
        guard let directory else { return nil }
        return directory.deletingLastPathComponent().appendingPathComponent(slide.file)
    }

    var body: some View {
        if let url, let image = NSImage(contentsOf: url) {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Open this screen in Preview")
                Text("Shared screen · \(slide.time)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 4: Pass the directory in from the detail pane**

In `MeetingDetailView.body`, replace the `TranscriptReadingView(...)` call with:

```swift
            TranscriptReadingView(
                document: state.transcript(for: recording),
                localUserName: state.settings.localUserName,
                playback: playbackContext,
                slidesDirectory: state.slidesDirectory(for: recording)
            )
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Verify by running (N8) — the real end-to-end check**

Run: `./Scripts/build-app.sh --run`

Join a real meeting where a **remote participant shares their screen**, record a few
minutes with at least two slide changes, stop, and let it transcribe. Confirm all of:

- [ ] `slides/` in the bundle contains one JPEG per slide change, and **no images of
      participants' faces** from the talking-head stretches.
- [ ] `transcript.md` contains `![Shared screen …](slides/…)` lines positioned at the
      right points in the conversation.
- [ ] The detail pane shows each image inline with its "Shared screen · HH:mm:ss" caption,
      and clicking one opens Preview.
- [ ] **Both `mic.wav` and `system.wav` are still full wall-clock length** — the invariant
      this whole design protects. Check with
      `afinfo "<bundle>/system.wav" | grep duration` against the recording's real length.
- [ ] Per-line play buttons still work (R27 didn't regress).
- [ ] Turning the setting off and recording again produces **no** `slides/` directory.

Note the bundle path with:

```sh
ls -la ~/Library/Application\ Support/MeetingAssistant/
```

- [ ] **Step 8: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift
git commit -m "feat: show captured shared screens inline in the transcript"
```

---

## Task 11: Documentation

**Files:**
- Modify: `REQUIREMENTS.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Add R28 to REQUIREMENTS.md**

In the "Capture & recording" section, after the R3e entry, add:

```markdown
- **R28 — Capture shared screens.** When someone presents, the app saves a picture of
  the shared screen each time its content **materially changes**, anchored into the
  transcript at the point in the conversation where it appeared (clicking one opens it
  in Preview). **On by default**, with a single Settings → General toggle to turn it
  off. Detection is content-based and app-agnostic (a frame is kept when it holds
  still yet differs from the last kept frame), so talking-head galleries are not
  captured and a shared video is skipped. **Only the meeting window is ever
  captured** — so the user's *own* share is caught only when their conferencing app
  echoes it back into that window (Google Meet does; Zoom generally does not), which
  is accepted as best-effort. Best-effort and never fatal (N3): a failure here never
  affects the recording or the transcript.
```

- [ ] **Step 2: Amend R26 (retention)**

In the R26 entry, after the sentence ending "(default 1 year)", add:

```markdown
  **Captured slides (R28) follow the transcript window, not the audio one** — the
  transcript is anchored to them, so expiring them early would leave holes in a
  document the user chose to keep. They are counted in the storage figures like
  everything else.
```

- [ ] **Step 3: Amend N1b (consent)**

Append to the N1b entry:

```markdown
  A **shared screen is a higher sensitivity class than speech** (a customer's
  dashboard, CRM, or inbox may appear on it), which is why slide capture (R28) never
  looks outside the meeting window and is a single, visible toggle rather than a
  buried option.
```

- [ ] **Step 4: Update CLAUDE.md**

In the "Pipeline" code block, change the `CaptureSession` line to:

```
  → CaptureSession  [LIVE: ScreenCaptureKit system audio + AVAudioEngine mic + SpeakerSampler frames + SlideRecorder keyframes]
```

After the "Speaker labeling has two signals…" section, add:

```markdown
### Shared-screen capture reuses the frame the speaker sampler already gets

`SlideRecorder` (an actor) saves a JPEG whenever the presented content changes: each
sampled frame becomes a 16×16 grey `FrameSignature`, and the pure `SlideChangeDetector`
keeps a frame that is *holding still* (barely differs from the previous sample) yet *new*
(differs from the last kept frame). Talking heads never hold still, so faces aren't
captured; a shared video keeps moving and is skipped. Keyframes land in the bundle's
`slides/`, are listed in `recording.json` (`MeetingRecording.slides`), written into
`transcript.md` as Markdown image lines by `TranscriptFormatter`, and recovered by
`TranscriptParser` into `Parsed.slides` — **kept separate from `Parsed.turns`**, because
`TranscriptAudioLocator` matches turns positionally against `segments.json` and extra
entries would silently break per-line playback.

**All slide work must stay off `CaptureSession.outputQueue.`** That queue is serial and
serves *both* the system-audio and screen-frame outputs, so CoreImage/file work in the
handler back-pressures audio delivery; ScreenCaptureKit then sheds samples, and since
`system.wav` is written by appending buffers with no timestamps, shed samples silently
shorten the file and shift every later timestamp. Keep the work inside the `Task` that
`handleVideoFrame` spawns.
```

In the "Pure logic vs. integrations (what's tested)" list, add `SlideChangeDetector` to
the tested modules.

- [ ] **Step 5: Commit — CLAUDE.md only**

`REQUIREMENTS.md` is **gitignored on purpose** ("Product requirements — kept local, not
published" in `.gitignore`) and is being removed from tracking, so `git add
REQUIREMENTS.md` would fail. Edit it locally as Steps 1–3 describe, but commit only
`CLAUDE.md`:

```bash
git add CLAUDE.md
git commit -m "docs: note shared-screen capture in the architecture guide"
git status --short   # REQUIREMENTS.md should not appear as staged
```

---

## Definition of done

- [ ] `swift build` and `swift test` both clean.
- [ ] A recorded meeting with a remote screen share produces keyframes in `slides/`, image
      lines in `transcript.md`, and inline images in the detail pane.
- [ ] No keyframes of participants' faces from talking-head stretches.
- [ ] `mic.wav` and `system.wav` are still full wall-clock length after a slide-heavy
      meeting.
- [ ] R27 per-line playback still works.
- [ ] The Settings toggle is on by default, persists, and turning it off produces no
      `slides/` directory.
- [ ] A meeting with no share produces a transcript identical in shape to before.
- [ ] The temporary calibration probe from Task 1 is **not** in the shipped source
      (`git grep PROBE Sources/` returns nothing).
