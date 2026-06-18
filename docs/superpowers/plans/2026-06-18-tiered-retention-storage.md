# Tiered Retention & Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-expire heavy meeting audio after a configurable window while keeping lightweight transcripts far longer, and let the user see and reclaim disk space — without ever deleting recognized voices' fingerprints.

**Architecture:** A pure `RetentionPolicy` in MeetingKit makes the age-based delete decisions. `MeetingStore` gains size accounting, media-only expiry, and a `sweep` that only touches valid meeting bundles (directories containing `recording.json`), structurally protecting the root-level global `speakers.json`. `AppState` runs the sweep on launch + a 24h timer (skipping any active meeting) and publishes total storage. UI surfaces an "audio cleared" state on the detail pane, a Settings → Storage section, and a footer total.

**Tech Stack:** Swift, SwiftUI, swift-testing (`import Testing`), Foundation `FileManager`/`ByteCountFormatter`.

**Spec:** `docs/superpowers/specs/2026-06-18-tiered-retention-storage-design.md`

---

## File structure

- **Create** `Sources/MeetingKit/RetentionPolicy.swift` — pure policy type + `RetentionSweepResult`.
- **Modify** `Sources/MeetingKit/MeetingStore.swift` — `bundleURL`, `hasAudio`, `expireMedia`, `bundleSize`, `totalSize`, `sweep`.
- **Modify** `Sources/MeetingAssistant/Settings.swift` — `mediaRetentionDays`, `transcriptRetentionDays`, `retentionPolicy`.
- **Modify** `Sources/MeetingAssistant/AppState.swift` — sweep on launch + timer, `activeRetentionIDs`, `storageBytes`, `cleanUpStorageNow`, refresh after delete.
- **Modify** `Sources/MeetingAssistant/MainWindowView.swift` — audio-expired note + disabled "Make Transcript Again"; sidebar footer "X GB used".
- **Modify** `Sources/MeetingAssistant/SettingsView.swift` — new Storage tab.
- **Create** `Tests/MeetingKitTests/RetentionPolicyTests.swift`
- **Create** `Tests/MeetingKitTests/MeetingStoreRetentionTests.swift`

Note: the detail-pane action menu (Save/Show in Finder/Make Transcript Again) is currently a `Menu`, which conflicts with R16b (buttons over menus). That restructure is **out of scope** here — this plan only disables "Make Transcript Again" when audio is gone. Track R16b separately.

---

## Task 1: `RetentionPolicy` pure type

**Files:**
- Create: `Sources/MeetingKit/RetentionPolicy.swift`
- Test: `Tests/MeetingKitTests/RetentionPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite struct RetentionPolicyTests {
    // A fixed clock so tests are deterministic.
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func expiresMediaPastWindow() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldExpireMedia(recordedAt: daysAgo(8), now: now) == true)
    }

    @Test func keepsMediaWithinWindow() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldExpireMedia(recordedAt: daysAgo(6), now: now) == false)
    }

    @Test func neverExpiresMediaWhenNil() {
        let p = RetentionPolicy(mediaMaxAge: nil, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldExpireMedia(recordedAt: daysAgo(999), now: now) == false)
    }

    @Test func deletesBundlePastTranscriptWindow() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        #expect(p.shouldDeleteBundle(recordedAt: daysAgo(366), now: now) == true)
        #expect(p.shouldDeleteBundle(recordedAt: daysAgo(364), now: now) == false)
    }

    @Test func neverDeletesBundleWhenNil() {
        let p = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: nil)
        #expect(p.shouldDeleteBundle(recordedAt: daysAgo(99_999), now: now) == false)
    }

    @Test func defaultIsSevenDaysAndOneYear() {
        #expect(RetentionPolicy.default.mediaMaxAge == 7 * 86_400)
        #expect(RetentionPolicy.default.transcriptMaxAge == 365 * 86_400)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RetentionPolicyTests`
Expected: FAIL — `cannot find 'RetentionPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure, time-based retention decisions for a meeting bundle. Two independent
/// windows: heavy audio expires first (`mediaMaxAge`); the whole bundle —
/// including the tiny transcript — is deleted only after `transcriptMaxAge`.
/// A `nil` window means "never" for that action. Injecting `now` keeps every
/// decision deterministic and unit-testable.
public struct RetentionPolicy: Equatable, Sendable {
    public var mediaMaxAge: TimeInterval?       // nil = never expire audio
    public var transcriptMaxAge: TimeInterval?  // nil = keep the bundle forever

    public init(mediaMaxAge: TimeInterval?, transcriptMaxAge: TimeInterval?) {
        self.mediaMaxAge = mediaMaxAge
        self.transcriptMaxAge = transcriptMaxAge
    }

    /// Defaults: audio 7 days, transcript 1 year.
    public static let `default` = RetentionPolicy(
        mediaMaxAge: 7 * 86_400,
        transcriptMaxAge: 365 * 86_400
    )

    /// True when the recording's audio is older than the media window.
    public func shouldExpireMedia(recordedAt: Date, now: Date) -> Bool {
        guard let mediaMaxAge else { return false }
        return now.timeIntervalSince(recordedAt) > mediaMaxAge
    }

    /// True when the entire bundle is older than the transcript window.
    public func shouldDeleteBundle(recordedAt: Date, now: Date) -> Bool {
        guard let transcriptMaxAge else { return false }
        return now.timeIntervalSince(recordedAt) > transcriptMaxAge
    }
}

/// What a single retention sweep reclaimed — for logging and the "Clean up now"
/// summary.
public struct RetentionSweepResult: Equatable, Sendable {
    public var bundlesDeleted: Int
    public var mediaExpired: Int
    public var bytesReclaimed: Int64

    public init(bundlesDeleted: Int = 0, mediaExpired: Int = 0, bytesReclaimed: Int64 = 0) {
        self.bundlesDeleted = bundlesDeleted
        self.mediaExpired = mediaExpired
        self.bytesReclaimed = bytesReclaimed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RetentionPolicyTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/RetentionPolicy.swift Tests/MeetingKitTests/RetentionPolicyTests.swift
git commit -m "feat: add RetentionPolicy for time-based media/transcript expiry"
```

---

## Task 2: `MeetingStore` size + media expiry helpers

**Files:**
- Modify: `Sources/MeetingKit/MeetingStore.swift`
- Test: `Tests/MeetingKitTests/MeetingStoreRetentionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite struct MeetingStoreRetentionTests {
    // Build a store rooted in a fresh temp dir.
    func makeStore() throws -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-retention-\(UUID().uuidString)", isDirectory: true)
        return (try MeetingStore(root: root), root)
    }

    // Write a full bundle (recording.json + both WAVs + transcript) for a meeting
    // recorded `daysAgo` days before `now`.
    @discardableResult
    func seed(_ store: MeetingStore, id: String, recordedAt: Date,
              micBytes: Int = 1_000, systemBytes: Int = 2_000) throws -> URL {
        let dir = try store.directory(for: id)
        let meeting = Meeting(id: id, title: "M", startDate: recordedAt, endDate: recordedAt,
                              provider: nil, joinURL: nil)
        try store.save(MeetingRecording(meeting: meeting, recordedAt: recordedAt,
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: [])))
        try store.saveTranscript("# M\n\ntranscript", for: id)
        try Data(count: micBytes).write(to: dir.appendingPathComponent("mic.wav"))
        try Data(count: systemBytes).write(to: dir.appendingPathComponent("system.wav"))
        return dir
    }

    @Test func hasAudioReflectsWavPresence() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "a", recordedAt: Date())
        #expect(store.hasAudio(meetingID: "a") == true)
        store.expireMedia(meetingID: "a")
        #expect(store.hasAudio(meetingID: "a") == false)
    }

    @Test func expireMediaDeletesOnlyWavsKeepsTranscript() throws {
        let (store, _) = try makeStore()
        let dir = try seed(store, id: "a", recordedAt: Date())
        store.expireMedia(meetingID: "a")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path) == true)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("recording.json").path) == true)
        #expect(store.transcript(for: "a") == "# M\n\ntranscript")
    }

    @Test func expireMediaIsIdempotent() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "a", recordedAt: Date())
        store.expireMedia(meetingID: "a")
        store.expireMedia(meetingID: "a") // must not throw or crash
        #expect(store.hasAudio(meetingID: "a") == false)
    }

    @Test func totalSizeCountsAllBundles() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "a", recordedAt: Date(), micBytes: 1_000, systemBytes: 2_000)
        try seed(store, id: "b", recordedAt: Date(), micBytes: 500, systemBytes: 500)
        // Both WAV sets (3_000 + 1_000) plus small json/md overhead.
        #expect(store.totalSize() >= 4_000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingStoreRetentionTests`
Expected: FAIL — `value of type 'MeetingStore' has no member 'hasAudio'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MeetingKit/MeetingStore.swift`, add a non-creating bundle-path helper
and the new methods. Add near `transcriptURL` (which already builds a path without
creating it):

```swift
    /// Bundle directory path for a meeting WITHOUT creating it (unlike
    /// `directory(for:)`). Used by read/expiry/size helpers so they never
    /// resurrect a deleted bundle as an empty folder.
    private func bundleURL(for meetingID: String) -> URL {
        root.appendingPathComponent(sanitize(meetingID), isDirectory: true)
    }

    /// Fixed audio filenames written by `CaptureSession`.
    private static let audioFiles = ["mic.wav", "system.wav"]

    /// True iff both audio files still exist — i.e. the recording can still be
    /// re-transcribed. False once media has been expired to reclaim space.
    public func hasAudio(meetingID: String) -> Bool {
        let dir = bundleURL(for: meetingID)
        return Self.audioFiles.allSatisfy {
            fileManager.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Delete just the heavy audio (mic.wav + system.wav), keeping the transcript,
    /// metadata, and per-meeting speaker map. Idempotent: a missing file is a no-op.
    public func expireMedia(meetingID: String) {
        let dir = bundleURL(for: meetingID)
        for name in Self.audioFiles {
            let url = dir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Total bytes on disk for one meeting bundle (0 if absent).
    public func bundleSize(meetingID: String) -> Int64 {
        directorySize(bundleURL(for: meetingID))
    }

    /// Total bytes on disk across all meeting bundles, for the "space used" view.
    public func totalSize() -> Int64 {
        directorySize(root)
    }

    /// Recursively sum the byte size of regular files under `url`.
    private func directorySize(_ url: URL) -> Int64 {
        guard let en = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingStoreRetentionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/MeetingStore.swift Tests/MeetingKitTests/MeetingStoreRetentionTests.swift
git commit -m "feat: MeetingStore hasAudio/expireMedia/bundleSize/totalSize"
```

---

## Task 3: `MeetingStore.sweep` (with voiceprint-preservation invariant)

**Files:**
- Modify: `Sources/MeetingKit/MeetingStore.swift`
- Test: `Tests/MeetingKitTests/MeetingStoreRetentionTests.swift` (extend)

- [ ] **Step 1: Write the failing test** (append these tests to the existing suite)

```swift
    @Test func sweepExpiresMediaButKeepsTranscriptInMediaWindow() throws {
        let (store, _) = try makeStore()
        let now = Date()
        let dir = try seed(store, id: "old", recordedAt: now.addingTimeInterval(-8 * 86_400))
        let policy = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        let result = store.sweep(policy: policy, now: now, activeIDs: [])
        #expect(result.mediaExpired == 1)
        #expect(result.bundlesDeleted == 0)
        #expect(store.hasAudio(meetingID: "old") == false)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.md").path) == true)
    }

    @Test func sweepDeletesWholeBundlePastTranscriptWindow() throws {
        let (store, _) = try makeStore()
        let now = Date()
        let dir = try seed(store, id: "ancient", recordedAt: now.addingTimeInterval(-400 * 86_400))
        let policy = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        let result = store.sweep(policy: policy, now: now, activeIDs: [])
        #expect(result.bundlesDeleted == 1)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test func sweepSkipsActiveMeetings() throws {
        let (store, _) = try makeStore()
        let now = Date()
        try seed(store, id: "busy", recordedAt: now.addingTimeInterval(-8 * 86_400))
        let policy = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        let result = store.sweep(policy: policy, now: now, activeIDs: ["busy"])
        #expect(result.mediaExpired == 0)
        #expect(store.hasAudio(meetingID: "busy") == true)
    }

    // The critical invariant: the global SpeakerLibrary lives as a root-level
    // `speakers.json` FILE (not a bundle dir). The sweep must never touch it.
    @Test func sweepNeverTouchesRootLevelSpeakerLibrary() throws {
        let (store, root) = try makeStore()
        let now = Date()
        // Simulate the global voiceprint library at the store root.
        let globalLib = root.appendingPathComponent("speakers.json")
        try Data("voiceprints".utf8).write(to: globalLib)
        try seed(store, id: "ancient", recordedAt: now.addingTimeInterval(-400 * 86_400))
        let policy = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        _ = store.sweep(policy: policy, now: now, activeIDs: [])
        #expect(FileManager.default.fileExists(atPath: globalLib.path) == true)
        #expect(try String(contentsOf: globalLib, encoding: .utf8) == "voiceprints")
    }

    @Test func sweepWithinAllWindowsDoesNothing() throws {
        let (store, _) = try makeStore()
        let now = Date()
        try seed(store, id: "fresh", recordedAt: now.addingTimeInterval(-1 * 86_400))
        let policy = RetentionPolicy(mediaMaxAge: 7 * 86_400, transcriptMaxAge: 365 * 86_400)
        let result = store.sweep(policy: policy, now: now, activeIDs: [])
        #expect(result == RetentionSweepResult())
        #expect(store.hasAudio(meetingID: "fresh") == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingStoreRetentionTests`
Expected: FAIL — `value of type 'MeetingStore' has no member 'sweep'`.

- [ ] **Step 3: Write minimal implementation** (add to `MeetingStore.swift`)

```swift
    /// Apply a retention policy across every meeting bundle. Bundle deletion
    /// (transcript window) takes precedence over media expiry. Skips any meeting in
    /// `activeIDs` (recording or transcribing now). Operates ONLY on directories
    /// that contain a `recording.json`, so the root-level global `speakers.json`
    /// (the cross-meeting voiceprint library) is structurally never touched.
    public func sweep(policy: RetentionPolicy, now: Date, activeIDs: Set<String>) -> RetentionSweepResult {
        var result = RetentionSweepResult()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return result }

        for dir in dirs {
            // Only valid meeting bundles — a directory with a decodable recording.json.
            let recordingJSON = dir.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: recordingJSON),
                  let rec = try? decoder.decode(MeetingRecording.self, from: data) else { continue }
            let id = rec.meeting.id
            guard !activeIDs.contains(id) else { continue }

            if policy.shouldDeleteBundle(recordedAt: rec.recordedAt, now: now) {
                let size = directorySize(dir)
                try? fileManager.removeItem(at: dir)
                result.bundlesDeleted += 1
                result.bytesReclaimed += size
            } else if policy.shouldExpireMedia(recordedAt: rec.recordedAt, now: now) {
                let before = directorySize(dir)
                expireMedia(meetingID: id)
                let reclaimed = before - directorySize(dir)
                if reclaimed > 0 {
                    result.mediaExpired += 1
                    result.bytesReclaimed += reclaimed
                }
            }
        }
        return result
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingStoreRetentionTests`
Expected: PASS (9 tests total in the suite).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/MeetingStore.swift Tests/MeetingKitTests/MeetingStoreRetentionTests.swift
git commit -m "feat: MeetingStore.sweep applies retention, never touches voiceprints"
```

---

## Task 4: Retention preferences in `AppSettings`

**Files:**
- Modify: `Sources/MeetingAssistant/Settings.swift`

No unit test (UserDefaults-backed `@MainActor` view-model; verified by running). Keep
the change mechanical and mirror the existing `transcriptionWorkers` pattern.

- [ ] **Step 1: Add stored properties + keys + computed policy**

In `Sources/MeetingAssistant/Settings.swift`, add after `identifyInRoomSpeakers`:

```swift
    /// Days to keep heavy audio before auto-deleting it. `0` means "Never".
    /// Default 7 (see RetentionPolicy.default / spec R26).
    @Published var mediaRetentionDays: Int {
        didSet { defaults.set(mediaRetentionDays, forKey: Keys.mediaRetentionDays) }
    }

    /// Days to keep the whole bundle (incl. transcript) before deleting it. `0`
    /// means "Never". Default 365.
    @Published var transcriptRetentionDays: Int {
        didSet { defaults.set(transcriptRetentionDays, forKey: Keys.transcriptRetentionDays) }
    }
```

Add to `enum Keys`:

```swift
        static let mediaRetentionDays = "mediaRetentionDays"
        static let transcriptRetentionDays = "transcriptRetentionDays"
```

In `init`, after the `identifyInRoomSpeakers` line, add (UserDefaults returns 0 for
an absent key — we treat absent as the default, but a user-set 0 means Never; use
`object(forKey:)` to distinguish absent from explicit 0):

```swift
        self.mediaRetentionDays = defaults.object(forKey: Keys.mediaRetentionDays) == nil
            ? 7 : defaults.integer(forKey: Keys.mediaRetentionDays)
        self.transcriptRetentionDays = defaults.object(forKey: Keys.transcriptRetentionDays) == nil
            ? 365 : defaults.integer(forKey: Keys.transcriptRetentionDays)
```

Add a computed policy (place after `isEnrolled`):

```swift
    /// The retention policy derived from the user's settings. `0 days` → `nil`
    /// (never expire) for that window.
    var retentionPolicy: RetentionPolicy {
        func age(_ days: Int) -> TimeInterval? { days <= 0 ? nil : TimeInterval(days) * 86_400 }
        return RetentionPolicy(
            mediaMaxAge: age(mediaRetentionDays),
            transcriptMaxAge: age(transcriptRetentionDays)
        )
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/Settings.swift
git commit -m "feat: persist media/transcript retention windows in settings"
```

---

## Task 5: `AppState` — sweep on launch + timer, total size, clean-up-now

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift`

No unit test (`@MainActor` coordinator with timers; verified by running). The pure
sweep logic is already covered in Tasks 1–3.

- [ ] **Step 1: Add published storage total + active-ids helper**

Near the other `@Published` properties (after `recordings`), add:

```swift
    /// Total bytes used by all saved recordings, shown in Settings → Storage and
    /// the sidebar footer. Refreshed after sweeps, deletes, and new recordings.
    @Published private(set) var storageBytes: Int64 = 0
```

Add a helper (near `deleteRecording`) that lists meetings that must never be swept —
the one recording now plus anything transcribing or queued:

```swift
    /// Meetings the retention sweep must skip: the live recording and everything in
    /// the transcription queue (current + pending).
    private var activeRetentionIDs: Set<String> {
        var ids = Set<String>()
        if let r = recording { ids.insert(r.id) }
        if let c = processing.current { ids.insert(c.id) }
        ids.formUnion(processing.pending.map(\.id))
        return ids
    }
```

(`ProcessingQueue.current: Meeting?` and `.pending: [Meeting]` are both public —
confirmed in `Sources/MeetingKit/ProcessingQueue.swift`.)

- [ ] **Step 2: Add the sweep entry points**

Add these methods to `AppState`:

```swift
    /// Run the retention sweep with the user's current policy, then refresh the
    /// recordings list and storage total. Safe to call from launch or a timer.
    func runRetentionSweep() {
        let result = store.sweep(
            policy: settings.retentionPolicy, now: Date(), activeIDs: activeRetentionIDs
        )
        if result.bundlesDeleted > 0 { recordings = store.allRecordings() }
        refreshStorageTotal()
    }

    /// User-triggered immediate cleanup (Settings → Storage → "Clean up now").
    func cleanUpStorageNow() { runRetentionSweep() }

    /// Recompute the published on-disk total.
    func refreshStorageTotal() { storageBytes = store.totalSize() }
```

- [ ] **Step 3: Wire launch sweep + 24h timer**

At the end of `init()`, after the existing setup, add:

```swift
        // Reclaim space from old recordings at launch, then once a day while running.
        runRetentionSweep()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runRetentionSweep() }
        }
```

Add the stored timer property near `cancellables`:

```swift
    /// Daily retention sweep timer (invalidated implicitly on dealloc).
    private var retentionTimer: Timer?
```

- [ ] **Step 4: Refresh total after manual delete**

In `deleteRecording(_:)`, after `recordings = store.allRecordings()`, add:

```swift
        refreshStorageTotal()
```

- [ ] **Step 5: Build + run to verify**

Run: `swift build`
Expected: builds cleanly.

Then sanity-run: `./Scripts/build-app.sh --run` and confirm the app launches and the
recordings list still loads (no crash from the launch sweep).

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: run retention sweep on launch + daily, publish storage total"
```

---

## Task 6: Detail pane — audio-expired state + disabled re-transcribe

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

No unit test (SwiftUI view; verified by running). The "Make Transcript Again" action
lives in the `Menu` around lines 359–371.

- [ ] **Step 1: Disable "Make Transcript Again" when audio is gone, with reason**

Replace the existing button (line ~368):

```swift
                Button("Make Transcript Again") { Task { await state.reprocess(recording) } }
                    .disabled(!state.modelReady)
```

with one that also checks audio presence:

```swift
                Button("Make Transcript Again") { Task { await state.reprocess(recording) } }
                    .disabled(!state.modelReady || !state.hasAudio(for: recording))
```

- [ ] **Step 2: Add the `hasAudio(for:)` passthrough on `AppState`**

In `Sources/MeetingAssistant/AppState.swift`, near `transcript(for:)`:

```swift
    /// Whether a saved recording still has its audio (so it can be re-transcribed).
    /// False once retention has expired the WAVs to save space.
    func hasAudio(for recording: MeetingRecording) -> Bool {
        store.hasAudio(meetingID: recording.meeting.id)
    }
```

- [ ] **Step 3: Show an "audio cleared" note in the detail header**

Find the detail header `VStack(alignment: .leading, spacing: 3)` (around line 306)
that renders the title/date. After its date line, add a conditional note:

```swift
                if !state.hasAudio(for: recording) {
                    Label("Audio cleared to save space — transcript kept. Re-transcribing isn’t available.",
                          systemImage: "externaldrive.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

> Match the surrounding view's exact indentation/structure; if the header is a
> separate computed property, add the note there. The text must read as
> informational, not an error (R26 / N3).

- [ ] **Step 4: Build + run to verify**

Run: `swift build`
Expected: builds cleanly.

To exercise the state without waiting 7 days: temporarily set
`mediaRetentionDays = 0`? No — 0 means Never. Instead, in Settings pick the
smallest window (added in Task 7) or manually delete a bundle's `mic.wav`/
`system.wav` in
`~/Library/Application Support/MeetingAssistant/<id>/`, relaunch, select that
meeting, and confirm the note shows and "Make Transcript Again" is disabled.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift Sources/MeetingAssistant/AppState.swift
git commit -m "feat: show audio-cleared state and disable re-transcribe when expired"
```

---

## Task 7: Settings → Storage tab

**Files:**
- Modify: `Sources/MeetingAssistant/SettingsView.swift`

No unit test (SwiftUI view). Follow the existing tab/`Form`/`Picker` patterns.

- [ ] **Step 1: Add the tab to the `TabView`**

In `body`, add after the `modelsTab` line:

```swift
            storageTab.tabItem { Label("Storage", systemImage: "internaldrive") }
```

- [ ] **Step 2: Implement the storage tab**

Add this computed property to `SettingsView`:

```swift
    // MARK: - Storage (retention)

    // Offered retention windows; 0 == "Never".
    private let mediaWindows: [(label: String, days: Int)] =
        [("3 days", 3), ("7 days", 7), ("14 days", 14), ("30 days", 30), ("Never", 0)]
    private let transcriptWindows: [(label: String, days: Int)] =
        [("90 days", 90), ("180 days", 180), ("1 year", 365), ("Never", 0)]

    private var storageTab: some View {
        Form {
            Section("Space used") {
                HStack {
                    Text("All recordings")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: state.storageBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Button("Clean up now") { state.cleanUpStorageNow() }
            }
            Section("Keep audio for") {
                Picker("Audio", selection: Binding(
                    get: { state.settings.mediaRetentionDays },
                    set: { state.settings.mediaRetentionDays = $0 }
                )) {
                    ForEach(mediaWindows, id: \.days) { Text($0.label).tag($0.days) }
                }
                .onChange(of: state.settings.mediaRetentionDays) { state.runRetentionSweep() }
                Text("Recordings are large. Their audio is deleted automatically after "
                     + "this long to free space; the transcript is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keep transcripts for") {
                Picker("Transcripts", selection: Binding(
                    get: { state.settings.transcriptRetentionDays },
                    set: { state.settings.transcriptRetentionDays = $0 }
                )) {
                    ForEach(transcriptWindows, id: \.days) { Text($0.label).tag($0.days) }
                }
                .onChange(of: state.settings.transcriptRetentionDays) { state.runRetentionSweep() }
                Text("Transcripts are tiny, so they can be kept much longer than the audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { state.refreshStorageTotal() }
    }
```

- [ ] **Step 3: Build + run to verify**

Run: `swift build`
Expected: builds cleanly.

Run the app, open Settings → Storage: confirm the total shows, both pickers reflect
defaults (7 days / 1 year), changing a window triggers a sweep, and "Clean up now"
works. Pick "3 days" to expire an older recording's audio and confirm the detail-pane
note from Task 6 appears.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingAssistant/SettingsView.swift
git commit -m "feat: add Settings > Storage with retention windows + clean up now"
```

---

## Task 8: Sidebar footer — "X GB used"

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

No unit test (SwiftUI view). The sidebar already uses `.safeAreaInset(edge: .top)`
for the record button (around line 34); mirror it on the bottom edge.

- [ ] **Step 1: Add a bottom safe-area inset to the sidebar**

On the `sidebarList` (the `List` with `.listStyle(.sidebar)` and the existing
`.safeAreaInset(edge: .top)` around lines 29–34), add a bottom inset directly after
the top one:

```swift
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive").font(.system(size: 11))
                    Text("\(ByteCountFormatter.string(fromByteCount: state.storageBytes, countStyle: .file)) used")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
            }
```

- [ ] **Step 2: Build + run to verify**

Run: `swift build`
Expected: builds cleanly.

Run the app: confirm the footer shows "… used" at the bottom of the sidebar and the
number drops after "Clean up now" reclaims space.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift
git commit -m "feat: show storage-used total in the sidebar footer"
```

---

## Task 9: Full verification + requirement status

**Files:**
- Modify: `REQUIREMENTS.md`

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: all suites pass, including `RetentionPolicyTests` and
`MeetingStoreRetentionTests`.

- [ ] **Step 2: End-to-end manual check**

Run: `./Scripts/build-app.sh --run`. Verify: launch sweep doesn't crash; Settings →
Storage total + pickers + "Clean up now" work; setting audio to "3 days" expires an
old recording's WAVs; that recording shows the "Audio cleared" note with
"Make Transcript Again" disabled while the transcript stays readable/copyable; the
sidebar footer total updates. Confirm the global speaker library file
(`~/Library/Application Support/MeetingAssistant/speakers.json`) still exists after a
sweep that deleted a bundle.

- [ ] **Step 3: Flip R26/N11 from *(planned)* to implemented**

In `REQUIREMENTS.md`, remove the ` *(planned)*` marker and the trailing
`*(Not yet implemented.)*` / `*(... do not.)*` caveats from **R26** and **N11**,
since both now ship (keep the wording otherwise).

- [ ] **Step 4: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: mark R26 + N11 (tiered retention & storage) as implemented"
```

---

## Self-review notes

- **Spec coverage:** RetentionPolicy (Task 1) ✓; expireMedia/hasAudio/sizes (Task 2) ✓;
  sweep + voiceprint invariant (Task 3) ✓; configurable windows w/ defaults 7d/1yr +
  Never (Tasks 4, 7) ✓; launch+24h sweep, skip active (Task 5) ✓; audio-expired UI +
  disabled re-transcribe (Task 6) ✓; Settings → Storage (Task 7) ✓; footer total
  (Task 8) ✓; manual delete still immediate (unchanged `deleteRecording`) ✓.
- **Out of scope (per spec):** size-cap cleanup, bulk delete, R16b menu→button
  restructure of the detail-pane action menu.
- **Type consistency:** `RetentionPolicy(mediaMaxAge:transcriptMaxAge:)`,
  `shouldExpireMedia`/`shouldDeleteBundle`, `RetentionSweepResult`,
  `store.sweep(policy:now:activeIDs:)`, `store.hasAudio(meetingID:)`,
  `state.hasAudio(for:)`, `state.storageBytes`, `state.runRetentionSweep()`,
  `state.cleanUpStorageNow()`, `state.refreshStorageTotal()`,
  `settings.mediaRetentionDays`/`transcriptRetentionDays`/`retentionPolicy` are used
  consistently across tasks.
- **APIs verified against source:** `ProcessingQueue.current`/`.pending` (public),
  `CaptureSession` audio filenames `mic.wav`/`system.wav`, `MeetingStore` init
  `root:`/`directory(for:)`/`sanitize`, global `SpeakerLibrary` at root-level
  `speakers.json`.
