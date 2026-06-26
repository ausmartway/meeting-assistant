# Window-scoped OCR + Remote-speaker voiceprint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Scope on-screen-name OCR to the meeting window only (ScreenCaptureKit window capture), and (2) when the on-screen active-speaker name isn't confidently a human name, identify remote speakers by voiceprint (lazy system-channel diarization).

**Architecture:** New pure modules `HumanNameClassifier` (confident-human-only) and `DisplaySelector.pickWindow` are unit-tested. `SpeakerRecognizer.resolve` gains unified `startingAnon` numbering; `SpeakerFuser` gets a remote voiceprint fallback. `CaptureSession` captures the meeting window instead of the display. `MeetingProcessor` lazily diarizes the system channel when a non-human name appears and persists a merged speaker map. The live-capture/post-processing split is preserved.

**Tech Stack:** Swift, SwiftPM, swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`), ScreenCaptureKit, Vision, FluidAudio diarization.

**Specs:**
- `docs/superpowers/specs/2026-06-26-window-scoped-ocr-capture-design.md`
- `docs/superpowers/specs/2026-06-26-remote-speaker-voiceprint-design.md`

---

## File Structure

- **Create** `Sources/MeetingKit/HumanNameClassifier.swift` — pure room/device vs human-name classifier.
- **Create** `Tests/MeetingKitTests/HumanNameClassifierTests.swift`.
- **Modify** `Sources/MeetingKit/DisplaySelector.swift` — `ScreenWindow.windowID`; new `pickWindow`; refactor `pickDisplay`.
- **Modify** `Tests/MeetingKitTests/DisplaySelectorTests.swift` — windowID in factory; `pickWindow` tests.
- **Modify** `Sources/MeetingKit/SpeakerRecognizer.swift` — `startingAnon` param.
- **Modify** `Tests/MeetingKitTests/SpeakerRecognizerTests.swift` — `startingAnon` test.
- **Modify** `Sources/MeetingKit/SpeakerFuser.swift` — remote voiceprint fallback; expose `activeSpeaker`.
- **Modify** `Tests/MeetingKitTests/SpeakerFuserTests.swift` — remote fallback tests.
- **Modify** `Sources/MeetingKit/CaptureSession.swift` — window-scoped capture + `captureSize` + reconcile watcher.
- **Create** `Tests/MeetingKitTests/CaptureSizeTests.swift` — pure `captureSize`.
- **Modify** `Sources/MeetingKit/MeetingProcessor.swift` — lazy system diarization + merged speaker map.
- **Modify** `Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift` — remote-voiceprint tests.
- **Modify** `REQUIREMENTS.md` — window-scoped capture + remote-voiceprint notes.

---

## Task 1: HumanNameClassifier

**Files:**
- Create: `Sources/MeetingKit/HumanNameClassifier.swift`
- Test: `Tests/MeetingKitTests/HumanNameClassifierTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/HumanNameClassifierTests.swift`:

```swift
import Testing
@testable import MeetingKit

@Suite("HumanNameClassifier.isHumanName")
struct HumanNameClassifierTests {

    @Test("confident human names are human")
    func humanNames() {
        #expect(HumanNameClassifier.isHumanName("John Smith"))
        #expect(HumanNameClassifier.isHumanName("Mei Chen"))
        #expect(HumanNameClassifier.isHumanName("李伟"))
        #expect(HumanNameClassifier.isHumanName("Alice"))
    }

    @Test("room and device names are not human")
    func roomAndDevice() {
        #expect(!HumanNameClassifier.isHumanName("Boardroom"))
        #expect(!HumanNameClassifier.isHumanName("Meeting Room 3"))
        #expect(!HumanNameClassifier.isHumanName("Poly Studio X50"))
        #expect(!HumanNameClassifier.isHumanName("会议室 A"))
        #expect(!HumanNameClassifier.isHumanName("Conference Room"))
    }

    @Test("ambiguous strings default to not-human (use voiceprints)")
    func ambiguousDefaultsToNonHuman() {
        #expect(!HumanNameClassifier.isHumanName("guest"))     // lowercase
        #expect(!HumanNameClassifier.isHumanName("x"))          // too short / lowercase
        #expect(!HumanNameClassifier.isHumanName("🎤"))         // not a name
        #expect(!HumanNameClassifier.isHumanName("a b c d e"))  // too many tokens
        #expect(!HumanNameClassifier.isHumanName(""))           // empty
        #expect(!HumanNameClassifier.isHumanName("MTR204"))     // all-caps + digit device id
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HumanNameClassifier`
Expected: FAIL — `cannot find 'HumanNameClassifier' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MeetingKit/HumanNameClassifier.swift`:

```swift
import Foundation

/// Decides whether an OCR'd on-screen label is confidently a person's name, or a
/// room/device endpoint name (or anything ambiguous). Per the design decision to
/// *default to voiceprints whenever unsure*, this returns `true` ONLY when the name
/// positively looks like a person AND shows no room/device signal — everything else
/// is `false`, so the caller falls back to voice-fingerprint identification.
/// Pure and unit-tested; best-effort and tunable.
public enum HumanNameClassifier {

    /// Distinctive room/meeting words — matched anywhere in the (lowercased) name.
    private static let roomSubstrings = [
        "room", "conference", "huddle", "boardroom", "meeting",
        "会议室", "會議室", "会议", "會議", "室",
    ]

    /// Device/brand/ambiguous words — matched as whole tokens only, so a human name
    /// that merely contains these letters isn't rejected.
    private static let deviceTokens: Set<String> = [
        "poly", "logitech", "cisco", "webex", "owl", "neat", "crestron",
        "tap", "rally", "studio", "lab", "mtr", "board", "office",
    ]

    public static func isHumanName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        // --- Non-human signals: any one means "not confidently human" ---
        for kw in roomSubstrings where lower.contains(kw) { return false }
        if trimmed.contains(where: { $0.isNumber }) { return false }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count > 3 { return false }
        for t in tokens {
            if deviceTokens.contains(t.lowercased()) { return false }
            let letters = t.filter { $0.isLetter }
            if letters.count >= 3, letters == letters.uppercased(),
                letters != letters.lowercased()
            {
                return false  // ALL-CAPS device id (e.g. "IBM", "MTR")
            }
        }

        // --- Positive human shape required for a confident "true" ---
        if tokens.count == 1, isCJK(tokens[0]) {
            return tokens[0].count >= 2 && tokens[0].count <= 4
        }
        for t in tokens {
            guard let first = t.first, first.isUppercase, t.allSatisfy({ $0.isLetter }) else {
                return false
            }
        }
        return true
    }

    /// All scalars are CJK ideographs (so a short CJK name is recognized as human).
    private static func isCJK(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            (0x4E00...0x9FFF).contains($0.value)  // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains($0.value)  // Extension A
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HumanNameClassifier`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/HumanNameClassifier.swift Tests/MeetingKitTests/HumanNameClassifierTests.swift
git commit -m "feat: add HumanNameClassifier (confident-human-only, defaults to voiceprints)"
```

---

## Task 2: ScreenWindow.windowID + DisplaySelector.pickWindow

**Files:**
- Modify: `Sources/MeetingKit/DisplaySelector.swift`
- Modify: `Tests/MeetingKitTests/DisplaySelectorTests.swift`

- [ ] **Step 1: Add `windowID` to `ScreenWindow` and a `pickWindow` function; refactor `pickDisplay`**

In `Sources/MeetingKit/DisplaySelector.swift`, replace the `ScreenWindow` struct's stored properties + init with a version that carries a `windowID` (default `0` so other call sites keep compiling):

```swift
public struct ScreenWindow: Equatable, Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let bundleID: String?
    public let pid: pid_t

    public init(windowID: CGWindowID = 0, frame: CGRect, bundleID: String?, pid: pid_t) {
        self.windowID = windowID
        self.frame = frame
        self.bundleID = bundleID
        self.pid = pid
    }

    /// Pixel area; used to prefer the largest candidate window.
    public var area: CGFloat { frame.width * frame.height }
}
```

Then in the `DisplaySelector` enum, add `pickWindow` and refactor `pickDisplay` to reuse it. Replace the existing `pickDisplay(...)` body with:

```swift
    /// Pick the meeting window: the largest window owned by a preferred
    /// (conferencing-app) bundle ID; else the largest window owned by the frontmost
    /// app; else nil. The single shared selection rule for both window capture and
    /// display selection.
    public static func pickWindow(
        windows: [ScreenWindow],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?
    ) -> ScreenWindow? {
        let preferred = windows.filter { w in
            guard let b = w.bundleID else { return false }
            return preferredBundleIDs.contains(b)
        }
        if let best = largest(preferred) { return best }
        if let pid = frontmostPID, let best = largest(windows.filter { $0.pid == pid }) {
            return best
        }
        return nil
    }

    /// Pick the display showing the meeting: the meeting window's display, or nil
    /// (caller keeps the default display).
    public static func pickDisplay(
        windows: [ScreenWindow],
        displays: [ScreenDisplay],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?
    ) -> CGDirectDisplayID? {
        guard
            let window = pickWindow(
                windows: windows, preferredBundleIDs: preferredBundleIDs,
                frontmostPID: frontmostPID)
        else { return nil }
        return displayID(forWindow: window.frame, in: displays)
    }
```

(Leave `displayID(forWindow:in:)` and `largest(_:)` unchanged.)

- [ ] **Step 2: Update the test factory and add `pickWindow` tests**

In `Tests/MeetingKitTests/DisplaySelectorTests.swift`, update the `win` factory to assign a distinct `windowID` and add a `pickWindow` suite. Change the factory:

```swift
    func win(_ x: CGFloat, w: CGFloat = 400, bundle: String?, pid: pid_t, id: CGWindowID = 1)
        -> ScreenWindow
    {
        ScreenWindow(
            windowID: id, frame: CGRect(x: x, y: 100, width: w, height: 300),
            bundleID: bundle, pid: pid)
    }
```

Then append, after the existing `DisplaySelectorTests` struct, a new suite:

```swift
@Suite struct PickWindowTests {
    func win(_ w: CGFloat, bundle: String?, pid: pid_t, id: CGWindowID) -> ScreenWindow {
        ScreenWindow(
            windowID: id, frame: CGRect(x: 0, y: 0, width: w, height: 300),
            bundleID: bundle, pid: pid)
    }

    @Test func largestPreferredWindowWins() {
        let windows = [
            win(400, bundle: "us.zoom.xos", pid: 1, id: 10),
            win(800, bundle: "us.zoom.xos", pid: 1, id: 11),
            win(900, bundle: "com.apple.Safari", pid: 2, id: 12),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 2)
        #expect(picked?.windowID == 11)
    }

    @Test func fallsBackToFrontmostWhenNoPreferred() {
        let windows = [
            win(400, bundle: "com.apple.Safari", pid: 2, id: 20),
            win(800, bundle: "com.apple.Notes", pid: 3, id: 21),
        ]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 3)
        #expect(picked?.windowID == 21)
    }

    @Test func nilWhenNeitherPreferredNorFrontmost() {
        let windows = [win(400, bundle: "com.apple.Safari", pid: 2, id: 30)]
        let picked = DisplaySelector.pickWindow(
            windows: windows, preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 9)
        #expect(picked == nil)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter DisplaySelector`
Expected: existing `pickDisplay` tests still PASS; new `PickWindowTests` PASS.
Run: `swift test --filter PickWindow`
Expected: PASS (3 tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingKit/DisplaySelector.swift Tests/MeetingKitTests/DisplaySelectorTests.swift
git commit -m "feat: add DisplaySelector.pickWindow + ScreenWindow.windowID; pickDisplay reuses it"
```

---

## Task 3: SpeakerRecognizer.resolve — unified `startingAnon` numbering

**Files:**
- Modify: `Sources/MeetingKit/SpeakerRecognizer.swift`
- Modify: `Tests/MeetingKitTests/SpeakerRecognizerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/MeetingKitTests/SpeakerRecognizerTests.swift` (inside its suite struct — match the existing suite's name; if unsure, add a new `@Suite struct SpeakerRecognizerStartingAnonTests { ... }` at file end):

```swift
@Suite struct SpeakerRecognizerStartingAnonTests {
    @Test("startingAnon offsets anonymous numbering for a second channel") 
    func startingAnonOffsets() {
        let outcome = DiarizationOutcome(
            spans: [
                DiarizedSpan(start: 0, end: 1, speakerID: "c1"),
                DiarizedSpan(start: 1, end: 2, speakerID: "c2"),
            ],
            embeddings: ["c1": [1, 0, 0], "c2": [0, 1, 0]])
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome, knownSpeakers: [], startingAnon: 5)
        #expect(labels["c1"] == "Speaker 5")
        #expect(labels["c2"] == "Speaker 6")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerRecognizerStartingAnon`
Expected: FAIL — `resolve` has no `startingAnon` argument (compile error).

- [ ] **Step 3: Add the parameter**

In `Sources/MeetingKit/SpeakerRecognizer.swift`, change the `resolve` signature to add `startingAnon: Int = 2` after `margin`:

```swift
    public static func resolve(
        outcome: DiarizationOutcome,
        knownSpeakers: [KnownSpeaker],
        threshold: Float = defaultThreshold,
        margin: Float = defaultMargin,
        startingAnon: Int = 2
    ) -> [String: String] {
```

Then change the anonymous counter initializer from `var nextAnon = 2` to:

```swift
        var nextAnon = startingAnon
```

(Leave everything else unchanged.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter SpeakerRecognizer`
Expected: PASS — the new test passes and all existing `SpeakerRecognizer` tests still pass (default `startingAnon: 2` preserves behavior).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerRecognizer.swift Tests/MeetingKitTests/SpeakerRecognizerTests.swift
git commit -m "feat: SpeakerRecognizer.resolve startingAnon for unified cross-channel numbering"
```

---

## Task 4: SpeakerFuser — remote voiceprint fallback

**Files:**
- Modify: `Sources/MeetingKit/SpeakerFuser.swift`
- Modify: `Tests/MeetingKitTests/SpeakerFuserTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MeetingKitTests/SpeakerFuserTests.swift` (inside its suite; if it uses helpers, mirror them — these build segments/timelines directly):

```swift
    @Test("remote segment with a non-human on-screen name uses the voiceprint label")
    func remoteNonHumanUsesVoiceprint() {
        let seg = TranscriptSegment(start: 0, end: 2, text: "hi", channel: .system)
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Boardroom")])
        let out = SpeakerFuser.fuse(
            segments: [seg],
            timeline: timeline,
            systemDiarization: [DiarizedSpan(start: 0, end: 2, speakerID: "r1")],
            systemLabels: ["r1": "Speaker 3"])
        #expect(out.first?.speaker == "Speaker 3")
    }

    @Test("remote segment with a human on-screen name keeps that name")
    func remoteHumanKeepsName() {
        let seg = TranscriptSegment(start: 0, end: 2, text: "hi", channel: .system)
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Alice")])
        let out = SpeakerFuser.fuse(
            segments: [seg],
            timeline: timeline,
            systemDiarization: [DiarizedSpan(start: 0, end: 2, speakerID: "r1")],
            systemLabels: ["r1": "Speaker 3"])
        #expect(out.first?.speaker == "Alice")
    }

    @Test("remote segment, non-human name, no voiceprint span → unknown label")
    func remoteNonHumanNoSpanUnknown() {
        let seg = TranscriptSegment(start: 0, end: 2, text: "hi", channel: .system)
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Boardroom")])
        let out = SpeakerFuser.fuse(segments: [seg], timeline: timeline)
        #expect(out.first?.speaker == "Speaker")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerFuser`
Expected: FAIL — `fuse` has no `systemDiarization`/`systemLabels` parameters (compile error).

- [ ] **Step 3: Implement the fallback**

In `Sources/MeetingKit/SpeakerFuser.swift`, add the two parameters to `fuse` (after `micLabels`, before `micLabel`):

```swift
        micLabels: [String: String] = [:],
        systemDiarization: [DiarizedSpan] = [],
        systemLabels: [String: String] = [:],
        micLabel: String = "Me",
        unknownLabel: String = "Speaker"
```

Replace the `.system` case body:

```swift
            case .system:
                // Trust a confident human on-screen name; otherwise (room/device or
                // ambiguous name, or none) identify the remote speaker by voiceprint;
                // failing that, the generic fallback.
                let ocr = activeSpeaker(at: midpoint, in: timeline)
                if let ocr, HumanNameClassifier.isHumanName(ocr) {
                    speaker = ocr
                } else if let s = span(at: midpoint, in: systemDiarization),
                    let label = systemLabels[s.speakerID]
                {
                    speaker = label
                } else {
                    speaker = unknownLabel
                }
```

Then change `activeSpeaker` from `private static` to `static` (internal) so `MeetingProcessor` can reuse it in Task 6:

```swift
    /// The on-screen active speaker's name at time `t`, or nil if unknown.
    /// `timeline.samples` is guaranteed sorted by timestamp.
    static func activeSpeaker(at t: TimeInterval, in timeline: SpeakerTimeline) -> String? {
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SpeakerFuser`
Expected: PASS — new tests pass; existing `SpeakerFuser` tests still pass (their system segments use human names like "Alice"/"Sam", which classify as human, so they keep their OCR name). If any existing test used a non-human-looking system label, reconcile it per the new (intended) behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerFuser.swift Tests/MeetingKitTests/SpeakerFuserTests.swift
git commit -m "feat: SpeakerFuser remote voiceprint fallback for non-human on-screen names"
```

---

## Task 5: CaptureSession — window-scoped capture

**Files:**
- Modify: `Sources/MeetingKit/CaptureSession.swift`
- Create: `Tests/MeetingKitTests/CaptureSizeTests.swift`

> Most of this task is ScreenCaptureKit integration (not unit-tested; verified by
> building and running). The one pure piece — `captureSize` — is unit-tested.

- [ ] **Step 1: Write the failing test for the pure sizing helper**

Create `Tests/MeetingKitTests/CaptureSizeTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import MeetingKit

@Suite("CaptureSession.captureSize")
struct CaptureSizeTests {
    @Test("scales by backing factor when under the cap")
    func underCap() {
        let (w, h) = CaptureSession.captureSize(for: CGSize(width: 400, height: 300), scale: 2, cap: 1920)
        #expect(w == 800)
        #expect(h == 600)
    }

    @Test("caps the longest side and preserves aspect ratio")
    func cappedAspect() {
        let (w, h) = CaptureSession.captureSize(for: CGSize(width: 2000, height: 1000), scale: 2, cap: 1920)
        // longest scaled side = 4000 → factor 1920/4000 = 0.48 → 1920 x 960
        #expect(w == 1920)
        #expect(h == 960)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureSize`
Expected: FAIL — `captureSize` not found.

- [ ] **Step 3: Implement `captureSize` (pure, static) in CaptureSession**

In `Sources/MeetingKit/CaptureSession.swift`, add this static helper (near the other private helpers, e.g. just above the `// MARK: - System audio + frames` section):

```swift
    /// Pixel size for the window-capture stream: the window's point size times the
    /// backing `scale`, with the longest side capped so OCR has detail without
    /// wasting memory. Aspect ratio is preserved. Pure + unit-tested.
    static func captureSize(for points: CGSize, scale: CGFloat = 2, cap: CGFloat = 1920)
        -> (Int, Int)
    {
        let w = max(1, points.width) * scale
        let h = max(1, points.height) * scale
        let longest = max(w, h)
        let factor = longest > cap ? cap / longest : 1
        return (Int((w * factor).rounded()), Int((h * factor).rounded()))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureSize`
Expected: PASS (2 tests).

- [ ] **Step 5: Switch the state field from display to window**

In `Sources/MeetingKit/CaptureSession.swift`, change the stored property (around line 30):

```swift
    /// The window the video stream currently captures (for retarget detection).
    private var videoWindowID: CGWindowID?
```

(Replacing `private var videoDisplayID: CGDirectDisplayID?` and its comment.)

In `stop()`, change `videoDisplayID = nil` to `videoWindowID = nil`.

- [ ] **Step 6: Make video capture window-scoped**

Replace `startVideoStream(on display: SCDisplay)` entirely with a window-based version:

```swift
    /// Build + start a video-only stream capturing only `window`, replacing any
    /// current one. Make-before-break: the new stream starts before the old one
    /// stops, so a failed start leaves the existing capture running. Audio is on its
    /// own stream and untouched.
    private func startVideoStream(on window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let (w, h) = Self.captureSize(for: window.frame.size)
        config.width = w
        config.height = h
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)  // ~2 fps ceiling
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        let old = videoStream
        videoStream = stream
        videoWindowID = window.windowID
        if let old {
            try? await old.stopCapture()
        }
    }
```

- [ ] **Step 7: Replace `meetingDisplay(in:)` with `meetingWindow(in:)`**

Replace the `meetingDisplay(in content:)` method with:

```swift
    /// Choose the SCWindow showing the meeting via the pure `DisplaySelector.pickWindow`.
    private func meetingWindow(in content: SCShareableContent) -> SCWindow? {
        let windows = content.windows.map { w in
            ScreenWindow(
                windowID: w.windowID,
                frame: w.frame,
                bundleID: w.owningApplication?.bundleIdentifier,
                pid: w.owningApplication?.processID ?? 0)
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let chosen = DisplaySelector.pickWindow(
            windows: windows,
            preferredBundleIDs: meeting.provider?.meetingAppBundleIDs ?? [],
            frontmostPID: frontPID)
        guard let chosen else { return nil }
        return content.windows.first { $0.windowID == chosen.windowID }
    }
```

- [ ] **Step 8: Update `startSystemCapture` to target the window (strict skip)**

In `startSystemCapture`, replace the video-start block:

```swift
        // Video stream: target the meeting's display (falls back to the primary).
        let display = meetingDisplay(in: content) ?? primary
        try await startVideoStream(on: display)
        startRetargetWatcher()
```

with:

```swift
        // Video stream: capture ONLY the meeting window so OCR reads just the
        // meeting (and the rest of the desktop is never recorded). Strict: if no
        // meeting window is found, skip video entirely — the watcher will start it
        // if/when the window appears.
        if let window = meetingWindow(in: content) {
            try await startVideoStream(on: window)
        } else {
            Self.log.info("No meeting window found at start; video capture skipped")
        }
        startRetargetWatcher()
```

- [ ] **Step 9: Replace the retarget watcher body with reconcile logic**

Replace `retargetVideoIfMoved()` with `reconcileVideoTarget()` and update the call in `startRetargetWatcher` (change `await self?.retargetVideoIfMoved()` to `await self?.reconcileVideoTarget()`):

```swift
    private func reconcileVideoTarget() async {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        else { return }  // transient fetch failure → keep current stream
        guard let window = meetingWindow(in: content) else {
            // Meeting window gone — strict: capture nothing until it reappears.
            if let old = videoStream {
                try? await old.stopCapture()
                videoStream = nil
                videoWindowID = nil
                Self.log.info("Meeting window gone; video capture stopped")
            }
            return
        }
        guard window.windowID != videoWindowID else { return }  // unchanged → nothing to do
        do {
            try await startVideoStream(on: window)
            Self.log.info(
                "Re-targeted video capture to window \(window.windowID, privacy: .public)")
        } catch {
            Self.log.error(
                "Video re-target failed, keeping current window: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
```

- [ ] **Step 10: Build and run the full test suite**

Run: `swift build`
Expected: build succeeds. If the compiler reports `CGWindowID` is unresolved in `CaptureSession.swift`, add `import CoreGraphics` at the top.
Run: `swift test`
Expected: all tests pass (the new `CaptureSize` suite included; nothing else regresses).

- [ ] **Step 11: Commit**

```bash
git add Sources/MeetingKit/CaptureSession.swift Tests/MeetingKitTests/CaptureSizeTests.swift
git commit -m "feat: capture only the meeting window for OCR (window-scoped, strict skip)"
```

---

## Task 6: MeetingProcessor — lazy system diarization + merged speaker map

**Files:**
- Modify: `Sources/MeetingKit/MeetingProcessor.swift`
- Modify: `Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift`, add a call-recording diarizer and two-channel transcriber plus two tests. Add these helper types inside the `MeetingProcessorDiarizationTests` struct (alongside the existing private types):

```swift
    // Records which audio files it diarized, to prove laziness; returns one cluster.
    private final class RecordingDiarizer: Diarizing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var files: [String] = []
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func diarize(audioFile: URL, progress: TranscribeProgressHandler?) async throws
            -> DiarizationOutcome
        {
            lock.lock(); files.append(audioFile.lastPathComponent); lock.unlock()
            return DiarizationOutcome(
                spans: [DiarizedSpan(start: 0, end: 5, speakerID: "spk_a")],
                embeddings: ["spk_a": [1, 0, 0]])
        }
    }

    // One mic + one system segment, so a remote (system) label can be observed.
    private struct MicAndSystemTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?)
            async throws -> [TranscriptSegment]
        {
            channel == .microphone
                ? [TranscriptSegment(start: 0, end: 4, text: "hi from me", channel: .microphone)]
                : [TranscriptSegment(start: 0, end: 4, text: "hi from room", channel: .system)]
        }
    }

    private func makeRecording(timeline: SpeakerTimeline) throws -> (MeetingStore, MeetingRecording) {
        let store = try MeetingStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ma-remote-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav", timeline: timeline)
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        return (store, recording)
    }

    @Test("a non-human on-screen name triggers system diarization → remote voiceprint label")
    func nonHumanNameTriggersRemoteVoiceprint() async throws {
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Boardroom")])
        let (store, recording) = try makeRecording(timeline: timeline)
        let diarizer = RecordingDiarizer()
        let processor = MeetingProcessor(
            store: store, transcriber: MicAndSystemTranscriber(), diarizer: diarizer, knownSpeakers: [])
        let transcript = try await processor.process(recording)
        #expect(diarizer.files.contains("sys.wav"))      // system channel WAS diarized
        #expect(transcript.contains("Speaker 3:"))        // remote voiceprint (mic used Speaker 2)
        #expect(!transcript.contains("Boardroom"))        // room name not used as a speaker
    }

    @Test("all-human on-screen names skip system diarization")
    func humanNamesSkipRemoteDiarization() async throws {
        let timeline = SpeakerTimeline(samples: [SpeakerSample(timestamp: 0, speakerName: "Alice")])
        let (store, recording) = try makeRecording(timeline: timeline)
        let diarizer = RecordingDiarizer()
        let processor = MeetingProcessor(
            store: store, transcriber: MicAndSystemTranscriber(), diarizer: diarizer, knownSpeakers: [])
        let transcript = try await processor.process(recording)
        #expect(diarizer.files.contains("mic.wav"))       // mic always diarized
        #expect(!diarizer.files.contains("sys.wav"))       // system NOT diarized (lazy)
        #expect(transcript.contains("Alice:"))             // human on-screen name used
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingProcessor`
Expected: FAIL — `nonHumanNameTriggersRemoteVoiceprint` fails (no system diarization / no "Speaker 3"); compile may also fail if `needsRemoteDiarization` is referenced before it exists. (`humanNamesSkipRemoteDiarization` may pass by accident — that's fine.)

- [ ] **Step 3: Add the lazy-trigger helper**

In `Sources/MeetingKit/MeetingProcessor.swift`, add a private helper (e.g. just below `process(...)` or near `humanDuration`):

```swift
    /// True if any remote (system) segment's on-screen active-speaker name is not
    /// confidently a human name — meaning we should identify remote speakers by
    /// voiceprint instead. Uses the (already consolidated) OCR timeline.
    private func needsRemoteDiarization(
        segments: [TranscriptSegment], timeline: SpeakerTimeline
    ) -> Bool {
        for seg in segments where seg.channel == .system {
            let midpoint = (seg.start + seg.end) / 2
            if let name = SpeakerFuser.activeSpeaker(at: midpoint, in: timeline),
                !HumanNameClassifier.isHumanName(name)
            {
                return true
            }
        }
        return false
    }
```

- [ ] **Step 4: Wire lazy diarization + fusion**

In `process(...)`, the fusion block currently reads (after the merge of the prior OCR-robustness work):

```swift
        let micLabels = SpeakerRecognizer.resolve(outcome: outcome, knownSpeakers: knownSpeakers)
        // Multi-frame voting cleans OCR misreads/variants before fusion (post-processing).
        let consolidatedTimeline = SpeakerTimelineConsolidator.consolidate(recording.timeline)
        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: consolidatedTimeline,
            micDiarization: outcome.spans,
            micLabels: micLabels,
            micLabel: localUserName
        )
```

Replace it with:

```swift
        let micLabels = SpeakerRecognizer.resolve(outcome: outcome, knownSpeakers: knownSpeakers)
        // Multi-frame voting cleans OCR misreads/variants before fusion (post-processing).
        let consolidatedTimeline = SpeakerTimelineConsolidator.consolidate(recording.timeline)

        // 2c-remote. When the on-screen name of a remote speaker isn't confidently a
        // human name (a shared room/device endpoint), identify remote speakers by
        // voiceprint: diarize the system channel and resolve its clusters. Lazy —
        // skipped entirely when every remote name is a confident human name.
        var systemOutcome = DiarizationOutcome(spans: [], embeddings: [:])
        var systemLabels: [String: String] = [:]
        if needsRemoteDiarization(segments: cleaned, timeline: consolidatedTimeline) {
            do {
                systemOutcome = try await diarizer.diarize(
                    audioFile: systemURL, progress: onProgress)
                try Task.checkCancellation()
                let micAnon = micLabels.values.filter { $0.hasPrefix("Speaker ") }.count
                systemLabels = SpeakerRecognizer.resolve(
                    outcome: systemOutcome, knownSpeakers: knownSpeakers,
                    startingAnon: 2 + micAnon)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.error(
                    "System diarization failed; remote speakers stay anonymous: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: consolidatedTimeline,
            micDiarization: outcome.spans,
            micLabels: micLabels,
            systemDiarization: systemOutcome.spans,
            systemLabels: systemLabels,
            micLabel: localUserName
        )
```

- [ ] **Step 5: Persist a merged speaker map (mic ∪ namespaced system clusters)**

Replace the existing persistence block (2d):

```swift
        if !outcome.spans.isEmpty {
            try? store.saveSpeakerMap(
                MeetingSpeakerMap(
                    labelByCluster: micLabels, embeddingByCluster: outcome.embeddings),
                for: recording.meeting.id
            )
        }
```

with:

```swift
        // 2d. Persist the merged per-meeting speaker map so any speaker (local or
        //     remote) can be renamed later without re-diarizing. System cluster ids
        //     are namespaced ("sys:") so they can't collide with mic cluster ids;
        //     labels are already unique via the shared "Speaker N" numbering.
        var mapLabels = micLabels
        var mapEmbeddings = outcome.embeddings
        for (cluster, label) in systemLabels { mapLabels["sys:\(cluster)"] = label }
        for (cluster, emb) in systemOutcome.embeddings { mapEmbeddings["sys:\(cluster)"] = emb }
        if !mapLabels.isEmpty {
            try? store.saveSpeakerMap(
                MeetingSpeakerMap(labelByCluster: mapLabels, embeddingByCluster: mapEmbeddings),
                for: recording.meeting.id
            )
        }
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter MeetingProcessor`
Expected: PASS — both new tests pass and all existing `MeetingProcessor` tests still pass. Note the existing `persistsSpeakerMap` test (mic-only, `TwoSpeakerDiarizer`) still finds `labelByCluster["spk_a"] == "Speaker 2"` because mic clusters are stored un-namespaced.

- [ ] **Step 7: Run the full suite + build**

Run: `swift test`
Expected: all suites pass.
Run: `swift build`
Expected: full build (library + app) succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/MeetingKit/MeetingProcessor.swift Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift
git commit -m "feat: lazily diarize remote channel + voiceprint-identify room/device speakers"
```

---

## Task 7: Update REQUIREMENTS.md

**Files:**
- Modify: `REQUIREMENTS.md` (R10b paragraph, lines ~121-126)

- [ ] **Step 1: Make the change**

In `REQUIREMENTS.md`, append to the end of the R10b paragraph (after the sentence added by the prior OCR-robustness work):

```markdown
  Capture is **window-scoped**: only the meeting window's pixels are recorded for
  OCR (the rest of the desktop is never captured), and when no meeting window is
  found nothing is captured. When the on-screen active-speaker name is **not
  confidently a human name** (a shared room/device endpoint), the remote speaker is
  identified by **voice fingerprint** instead — the system-audio channel is diarized
  (lazily, only then) and its clusters resolved against the speaker library
  (`HumanNameClassifier`, `DisplaySelector.pickWindow`). Local and in-room speakers
  remain identified by voiceprint on the mic channel (R9).
```

- [ ] **Step 2: Verify it reads correctly**

Run: `rg -n -A6 "Best-effort on-screen names" REQUIREMENTS.md`
Expected: shows the R10b paragraph with the new sentences appended.

- [ ] **Step 3: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: note window-scoped capture + remote voiceprint ID in R10b"
```

---

## Verification (after all tasks)

- [ ] `swift test` — all suites green, including `HumanNameClassifier`, `PickWindow`, `CaptureSize`, the new `SpeakerFuser` + `SpeakerRecognizer` + `MeetingProcessor` tests.
- [ ] `swift build` — full build (library + app) succeeds.
- [ ] Manual (per project policy — ScreenCaptureKit/FluidAudio aren't unit-tested):
      run the app in a real meeting and confirm (a) OCR no longer picks up names
      from outside the meeting window, and (b) a meeting with a room/device-named
      remote endpoint produces distinct remote "Speaker N" labels rather than the
      room name.
```
