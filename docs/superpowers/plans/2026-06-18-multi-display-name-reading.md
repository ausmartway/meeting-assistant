# Multi-Display Name Reading (N13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the OCR video frames from the display that actually shows the meeting — including when it is on a secondary display, and following it if the window moves — without ever disturbing system-audio capture.

**Architecture:** A pure `DisplaySelector` (MeetingKit) decides which display shows the meeting from adapted window/display structs. `CaptureSession` splits its one combined `SCStream` into a stable **audio stream** (never re-targeted) and a re-targetable **video stream**, and a ~5 s watcher rebuilds only the video stream when the meeting moves displays. Per-provider bundle IDs are lifted to `MeetingProvider.meetingAppBundleIDs` as the single source of truth.

**Tech Stack:** Swift, ScreenCaptureKit, AppKit (`NSWorkspace`), CoreGraphics, swift-testing.

**Spec:** `docs/superpowers/specs/2026-06-18-multi-display-name-reading-design.md`

---

## File structure

- **Modify** `Sources/MeetingKit/Models.swift` — add `MeetingProvider.meetingAppBundleIDs`.
- **Modify** `Sources/MeetingKit/MeetingDetector.swift` — read from the shared mapping.
- **Create** `Sources/MeetingKit/DisplaySelector.swift` — `ScreenWindow`, `ScreenDisplay`, `DisplaySelector` (pure).
- **Modify** `Sources/MeetingKit/CaptureSession.swift` — two-stream split + re-target watcher.
- **Create** `Tests/MeetingKitTests/MeetingProviderBundleIDsTests.swift`.
- **Create** `Tests/MeetingKitTests/DisplaySelectorTests.swift`.
- **Modify** `REQUIREMENTS.md` — mark N13 implemented.

Reminder for all tasks: this repo uses **4-space indentation** (pinned by `.swift-format`). Stage only the files you change by explicit path; never `git add -A` or stage anything under `.claude/`. No AI/Claude mentions or Co-Authored-By trailers in commit messages. Ignore SourceKit "cannot find type" diagnostics — only trust `swift build` / `swift test`.

---

## Task 1: `MeetingProvider.meetingAppBundleIDs` (single source of truth)

**Files:**
- Modify: `Sources/MeetingKit/Models.swift`
- Modify: `Sources/MeetingKit/MeetingDetector.swift`
- Test: `Tests/MeetingKitTests/MeetingProviderBundleIDsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MeetingKit

@Suite struct MeetingProviderBundleIDsTests {
    @Test func zoomIsNativeOnly() {
        #expect(MeetingProvider.zoom.meetingAppBundleIDs == ["us.zoom.xos"])
    }

    @Test func meetIsBrowsersOnly() {
        #expect(MeetingProvider.googleMeet.meetingAppBundleIDs == MeetingProvider.browserBundleIDs)
    }

    @Test func teamsIncludesNativeAndBrowsers() {
        let ids = MeetingProvider.microsoftTeams.meetingAppBundleIDs
        #expect(ids.contains("com.microsoft.teams"))
        #expect(ids.contains("com.microsoft.teams2"))
        #expect(ids.isSuperset(of: MeetingProvider.browserBundleIDs))
    }

    @Test func webexIncludesNativeAndBrowsers() {
        let ids = MeetingProvider.webex.meetingAppBundleIDs
        #expect(ids.contains("com.cisco.webexmeetings"))
        #expect(ids.isSuperset(of: MeetingProvider.browserBundleIDs))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingProviderBundleIDsTests`
Expected: FAIL — `meetingAppBundleIDs`/`browserBundleIDs` not found.

- [ ] **Step 3: Add the mapping to `MeetingProvider` (in `Models.swift`)**

Add inside the `MeetingProvider` enum (after `shortName`):

```swift
    /// Browser bundle IDs that can host a web meeting (Meet, and Teams/Webex web).
    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
    ]

    /// Bundle IDs of the app(s) that can host a meeting for this provider — the
    /// single source of truth shared by meeting detection and display selection
    /// (so they can't drift). Native clients plus browsers where the provider runs
    /// on the web.
    public var meetingAppBundleIDs: Set<String> {
        switch self {
        case .zoom:
            return ["us.zoom.xos"]
        case .microsoftTeams:
            return ["com.microsoft.teams", "com.microsoft.teams2"].union(Self.browserBundleIDs)
        case .googleMeet:
            return Self.browserBundleIDs
        case .webex:
            return ["com.cisco.webexmeetings", "Cisco-Systems.Spark"].union(Self.browserBundleIDs)
        }
    }
```

- [ ] **Step 4: Point `MeetingDetector` at the shared mapping**

In `Sources/MeetingKit/MeetingDetector.swift`, delete the four private static arrays
(`zoomBundleIDs`, `browserBundleIDs`, `teamsBundleIDs`, `webexBundleIDs`) and replace
the body of `isMeetingAppRunning(for:)` with:

```swift
    public func isMeetingAppRunning(for provider: MeetingProvider) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !running.isDisjoint(with: provider.meetingAppBundleIDs)
    }
```

(This preserves the existing behavior: each provider's set already unions in the
browsers where applicable.)

- [ ] **Step 5: Run tests + build**

Run: `swift test --filter MeetingProviderBundleIDsTests` → PASS (4 tests).
Run: `swift build` → clean.
Run: `swift test --filter MeetingDetector` → existing detector tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/Models.swift Sources/MeetingKit/MeetingDetector.swift Tests/MeetingKitTests/MeetingProviderBundleIDsTests.swift
git commit -m "refactor: share meeting-app bundle IDs via MeetingProvider.meetingAppBundleIDs"
```

---

## Task 2: Pure `DisplaySelector`

**Files:**
- Create: `Sources/MeetingKit/DisplaySelector.swift`
- Test: `Tests/MeetingKitTests/DisplaySelectorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import CoreGraphics
import Foundation
@testable import MeetingKit

@Suite struct DisplaySelectorTests {
    // Two side-by-side 1000-wide displays: #1 at x=0, #2 at x=1000.
    let d1 = ScreenDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let d2 = ScreenDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    var displays: [ScreenDisplay] { [d1, d2] }

    func win(_ x: CGFloat, w: CGFloat = 400, bundle: String?, pid: pid_t) -> ScreenWindow {
        ScreenWindow(frame: CGRect(x: x, y: 100, width: w, height: 300), bundleID: bundle, pid: pid)
    }

    @Test func preferredWindowOnSecondDisplayWins() {
        // A big non-preferred window on display 1, a preferred meeting window on display 2.
        let windows = [
            win(100, w: 900, bundle: "com.other.app", pid: 10),
            win(1100, bundle: "us.zoom.xos", pid: 20),
        ]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 10)
        #expect(id == 2)
    }

    @Test func fallsBackToFrontmostWhenNoPreferred() {
        let windows = [
            win(100, bundle: "com.other.app", pid: 10),
            win(1100, bundle: "com.notes.app", pid: 20),
        ]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 20)
        #expect(id == 2)  // frontmost pid 20 is on display 2
    }

    @Test func nilWhenNeitherPreferredNorFrontmostMatch() {
        let windows = [win(100, bundle: "com.other.app", pid: 10)]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: 999)
        #expect(id == nil)
    }

    @Test func largestPreferredWindowWins() {
        let windows = [
            win(50, w: 200, bundle: "us.zoom.xos", pid: 10),      // small, display 1
            win(1100, w: 800, bundle: "us.zoom.xos", pid: 10),    // large, display 2
        ]
        let id = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: ["us.zoom.xos"], frontmostPID: nil)
        #expect(id == 2)
    }

    @Test func displayIDForWindowUsesMaxOverlap() {
        // Window straddles the seam but mostly on display 1: x 400..1200 → 600 px on
        // display 1 (0..1000) vs 200 px on display 2 (1000..2000).
        let straddling = CGRect(x: 400, y: 100, width: 800, height: 300)
        #expect(DisplaySelector.displayID(forWindow: straddling, in: displays) == 1)
        // Window fully on display 2.
        let onD2 = CGRect(x: 1200, y: 100, width: 300, height: 300)
        #expect(DisplaySelector.displayID(forWindow: onD2, in: displays) == 2)
        // Window off all displays.
        let off = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        #expect(DisplaySelector.displayID(forWindow: off, in: displays) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DisplaySelectorTests`
Expected: FAIL — `ScreenWindow`/`ScreenDisplay`/`DisplaySelector` not found.

- [ ] **Step 3: Implement `Sources/MeetingKit/DisplaySelector.swift`**

```swift
import CoreGraphics
import Foundation

/// A captured on-screen window, adapted from `SCWindow` so the selection logic is
/// pure and testable without ScreenCaptureKit.
public struct ScreenWindow: Equatable, Sendable {
    public let frame: CGRect
    public let bundleID: String?
    public let pid: pid_t

    public init(frame: CGRect, bundleID: String?, pid: pid_t) {
        self.frame = frame
        self.bundleID = bundleID
        self.pid = pid
    }

    /// Pixel area; used to prefer the largest candidate window.
    public var area: CGFloat { frame.width * frame.height }
}

/// A display, adapted from `SCDisplay`.
public struct ScreenDisplay: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let frame: CGRect

    public init(id: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// Pure logic that decides which display is showing the meeting. See N13 design.
public enum DisplaySelector {
    /// Pick the display showing the meeting: the largest window owned by a preferred
    /// (conferencing-app) bundle ID → its display; else the largest window owned by
    /// the frontmost app → its display; else nil (caller keeps the default display).
    public static func pickDisplay(
        windows: [ScreenWindow],
        displays: [ScreenDisplay],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?
    ) -> CGDirectDisplayID? {
        let preferred = windows.filter { w in
            guard let b = w.bundleID else { return false }
            return preferredBundleIDs.contains(b)
        }
        if let best = largest(preferred) {
            return displayID(forWindow: best.frame, in: displays)
        }
        if let pid = frontmostPID {
            if let best = largest(windows.filter { $0.pid == pid }) {
                return displayID(forWindow: best.frame, in: displays)
            }
        }
        return nil
    }

    /// The display whose frame overlaps `windowFrame` the most; nil if none overlap.
    public static func displayID(forWindow windowFrame: CGRect, in displays: [ScreenDisplay]) -> CGDirectDisplayID? {
        var bestID: CGDirectDisplayID?
        var bestArea: CGFloat = 0
        for d in displays {
            let overlap = d.frame.intersection(windowFrame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestID = d.id
            }
        }
        return bestID
    }

    private static func largest(_ windows: [ScreenWindow]) -> ScreenWindow? {
        windows.max(by: { $0.area < $1.area })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DisplaySelectorTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/DisplaySelector.swift Tests/MeetingKitTests/DisplaySelectorTests.swift
git commit -m "feat: add pure DisplaySelector for choosing the meeting's display"
```

---

## Task 3: Split CaptureSession into audio + video streams (pick at start)

**Files:**
- Modify: `Sources/MeetingKit/CaptureSession.swift`

No unit test — ScreenCaptureKit integration is verified by build + running (per N8).
This task delivers correct display selection **at start**; the move watcher is Task 4.

- [ ] **Step 1: Replace the single `stream` with two streams + display state**

In `CaptureSession`, replace:

```swift
    private var stream: SCStream?
```

with:

```swift
    private var audioStream: SCStream?
    private var videoStream: SCStream?
    /// The display the video stream currently captures (for move detection).
    private var videoDisplayID: CGDirectDisplayID?
```

Add `import CoreGraphics` at the top if not already present (ScreenCaptureKit
re-exports CoreGraphics, but be explicit).

- [ ] **Step 2: Replace `startSystemCapture` with the two-stream version**

Replace the entire `startSystemCapture(systemAudioURL:)` method with:

```swift
    private func startSystemCapture(systemAudioURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let primary = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Audio stream: any display works (system audio is global). Started once and
        // never re-targeted, so following the meeting across displays for video can
        // never interrupt audio.
        let audioFilter = SCContentFilter(
            display: primary, excludingApplications: [], exceptingWindows: [])
        let audioConfig = SCStreamConfiguration()
        audioConfig.capturesAudio = true
        audioConfig.excludesCurrentProcessAudio = true
        audioConfig.sampleRate = 16_000
        audioConfig.channelCount = 1
        let audio = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
        try audio.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        self.audioStream = audio
        try await audio.startCapture()

        // Video stream: target the meeting's display (falls back to the primary).
        let display = meetingDisplay(in: content) ?? primary
        try await startVideoStream(on: display)
    }

    /// Build + start a video-only stream on `display`, replacing any current one.
    private func startVideoStream(on display: SCDisplay) async throws {
        if let old = videoStream {
            try? await old.stopCapture()
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.width = 1280
        config.height = 720
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)  // ~2 fps ceiling
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        self.videoStream = stream
        self.videoDisplayID = display.displayID
        try await stream.startCapture()
    }

    /// Choose the SCDisplay showing the meeting via the pure `DisplaySelector`.
    private func meetingDisplay(in content: SCShareableContent) -> SCDisplay? {
        let windows = content.windows.map { w in
            ScreenWindow(
                frame: w.frame,
                bundleID: w.owningApplication?.bundleIdentifier,
                pid: w.owningApplication?.processID ?? 0)
        }
        let displays = content.displays.map { ScreenDisplay(id: $0.displayID, frame: $0.frame) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let chosen = DisplaySelector.pickDisplay(
            windows: windows, displays: displays,
            preferredBundleIDs: meeting.provider?.meetingAppBundleIDs ?? [],
            frontmostPID: frontPID)
        guard let chosen else { return nil }
        return content.displays.first { $0.displayID == chosen }
    }
```

Add `import AppKit` at the top of the file (for `NSWorkspace`) if not present.

- [ ] **Step 3: Update `stop()` to tear down both streams**

In `stop()`, replace:

```swift
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
```

with:

```swift
        if let videoStream {
            try? await videoStream.stopCapture()
        }
        if let audioStream {
            try? await audioStream.stopCapture()
        }
        videoStream = nil
        audioStream = nil
        videoDisplayID = nil
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Run + verify (two displays)**

Run: `./Scripts/build-app.sh --run`. With a meeting (or any conferencing app window)
on a **secondary** display, start a manual recording. Confirm the app captures
without crashing, audio (`system.wav`) records, and frames are sampled from the
secondary display (the resulting transcript's remote-speaker names work). With a
single display, behavior is unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/CaptureSession.swift
git commit -m "feat: capture OCR frames from the meeting's display, split from audio (N13)"
```

---

## Task 4: Re-target the video stream when the meeting moves displays

**Files:**
- Modify: `Sources/MeetingKit/CaptureSession.swift`

No unit test — verified by running. Builds on Task 3.

- [ ] **Step 1: Add a watcher task property**

Near the other private properties, add:

```swift
    /// Periodically re-checks which display shows the meeting and rebuilds the video
    /// stream if it moved. Never touches the audio stream.
    private var retargetTask: Task<Void, Never>?
```

- [ ] **Step 2: Start the watcher after the video stream starts**

At the end of `startSystemCapture(systemAudioURL:)` (after the `try await
startVideoStream(on: display)` line), add:

```swift
        startRetargetWatcher()
```

Add the watcher methods:

```swift
    /// Every ~5 s, if the meeting has moved to a different display, rebuild the
    /// video stream there. Best-effort: any failure leaves the current stream running.
    private func startRetargetWatcher() {
        retargetTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await self?.retargetVideoIfMoved()
            }
        }
    }

    private func retargetVideoIfMoved() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return }
        guard let display = meetingDisplay(in: content) else { return }  // not found → keep current
        guard display.displayID != videoDisplayID else { return }        // unchanged → nothing to do
        do {
            try await startVideoStream(on: display)
            Self.log.info("Re-targeted video capture to display \(display.displayID, privacy: .public)")
        } catch {
            Self.log.error("Video re-target failed; keeping current display")
        }
    }
```

- [ ] **Step 3: Cancel the watcher in `stop()`**

In `stop()`, before stopping the streams, add:

```swift
        retargetTask?.cancel()
        retargetTask = nil
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Run + verify (move across displays)**

Run: `./Scripts/build-app.sh --run`. Start a recording with the meeting on display 1,
then drag the meeting window to display 2 mid-recording. Within ~5 s the frame sampling
should follow to display 2 (verify via the resulting names / by observing it doesn't
crash), and **audio keeps recording uninterrupted** the whole time. Stopping ends both
streams cleanly.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/CaptureSession.swift
git commit -m "feat: follow the meeting across displays mid-recording (N13)"
```

---

## Task 5: Capture-path review + verification + requirement status

**Files:**
- Modify: `REQUIREMENTS.md`

- [ ] **Step 1: Capture-path review**

Because Tasks 3–4 changed the live capture path, have the **capture-path-reviewer**
subagent review the `CaptureSession` diff against the CLAUDE.md invariants
(mic-survives-route-changes, cheap-live-capture, no audio loss). Address any
correctness findings before proceeding.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: all suites pass, including `MeetingProviderBundleIDsTests` and
`DisplaySelectorTests`.

- [ ] **Step 3: Mark N13 implemented**

In `REQUIREMENTS.md`, the **N13** entry currently reads:

```
- **N13 — Multi-display name reading *(planned)*.** On-screen name reading should also
  work when the meeting window is on a secondary display. *(A single display is
  assumed today.)*
```

Replace it with:

```
- **N13 — Multi-display name reading.** On-screen name reading works when the meeting
  window is on a secondary display, and follows the window if it moves displays
  mid-meeting. Video frame capture targets the meeting's display (the conferencing
  app's window, else the frontmost window); system-audio capture runs on its own
  independent stream so re-targeting never interrupts it.
```

- [ ] **Step 4: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: mark N13 (multi-display name reading) as implemented"
```

---

## Self-review notes

- **Spec coverage:** shared `meetingAppBundleIDs` (Task 1) ✓; pure `DisplaySelector` +
  `ScreenWindow`/`ScreenDisplay` with preferred→frontmost→nil and max-overlap geometry
  (Task 2) ✓; two-stream split with audio stable + video on the meeting's display
  (Task 3) ✓; ~5 s re-target watcher rebuilding only the video stream (Task 4) ✓;
  capture-path review + REQUIREMENTS update (Task 5) ✓; all edge cases degrade to
  keeping the current/primary display.
- **Placeholder scan:** none — every step shows concrete code.
- **Type consistency:** `MeetingProvider.meetingAppBundleIDs` / `.browserBundleIDs`;
  `DisplaySelector.pickDisplay(windows:displays:preferredBundleIDs:frontmostPID:)` and
  `displayID(forWindow:in:)`; `ScreenWindow(frame:bundleID:pid:)`,
  `ScreenDisplay(id:frame:)`; `CaptureSession.audioStream`/`videoStream`/
  `videoDisplayID`/`retargetTask`, `startVideoStream(on:)`, `meetingDisplay(in:)` —
  used consistently. `SCWindow.owningApplication?.processID` is `pid_t`;
  `SCDisplay.displayID` is `CGDirectDisplayID`.
- **Out of scope (per spec):** multi-display simultaneous capture, per-window cropping,
  sub-5 s tracking, any mic/audio-format/transcription change.
