# Local-User Name + Fresh Re-recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Label the local user by an editable real name (defaulting to the macOS account name) instead of "Me", and make re-transcribing a meeting wipe its previous speaker identifications and re-recognize from scratch.

**Architecture:** A pure `LocalUserName.resolve` picks the name; `AppSettings.localUserName` persists it (default `NSFullUserName()`). The name is emitted at the source — `SpeakerFuser` mic label + the speaker library's `isMe` entry (renamed via `SpeakerLibrary.setLocalUserName`, migrating an existing "Me"). `MeetingProcessor.process` deletes the per-meeting speaker map at the start (`MeetingStore.deleteSpeakerMap`) so re-transcription starts fresh. The global voiceprint library is untouched.

**Tech Stack:** Swift, SwiftUI, Foundation (`NSFullUserName`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-06-19-local-user-name-and-fresh-rerecognition-design.md`

---

## File structure

- **Create** `Sources/MeetingKit/LocalUserName.swift` — pure name resolver.
- **Modify** `Sources/MeetingKit/SpeakerLibrary.swift` — `setLocalUserName(_:)`.
- **Modify** `Sources/MeetingKit/MeetingStore.swift` — `deleteSpeakerMap(for:)`.
- **Modify** `Sources/MeetingKit/MeetingProcessor.swift` — `localUserName` (init + fuse) + delete-map-at-start.
- **Modify** `Sources/MeetingAssistant/Settings.swift` — `localUserName` setting.
- **Modify** `Sources/MeetingAssistant/AppState.swift` — enroll name, launch sync, pass name to processor, `applyLocalUserName()`.
- **Modify** `Sources/MeetingAssistant/MainWindowView.swift` + `Sources/MeetingAssistant/SettingsView.swift` — "me" highlight by name + editable name field.
- **Create** `Tests/MeetingKitTests/LocalUserNameTests.swift`, `Tests/MeetingKitTests/SpeakerLibraryLocalUserTests.swift`; extend `MeetingStoreRetentionTests` and `SpeakerFuserTests`.
- **Modify** `REQUIREMENTS.md` — record the behavior.

Reminders: **4-space indentation** (pinned by `.swift-format`); stage only files you change by explicit path (never `git add -A` / `.claude/`); no AI/Claude mentions or Co-Authored-By trailers; ignore SourceKit "cannot find type" noise — trust `swift build`/`swift test`; finish each task by committing.

---

## Task 1: Pure `LocalUserName` resolver

**Files:**
- Create: `Sources/MeetingKit/LocalUserName.swift`
- Test: `Tests/MeetingKitTests/LocalUserNameTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MeetingKit

@Suite struct LocalUserNameTests {
    @Test func overrideWins() {
        #expect(LocalUserName.resolve(override: "Nick", accountName: "Yulei Liu") == "Nick")
    }
    @Test func blankOverrideFallsBackToAccount() {
        #expect(LocalUserName.resolve(override: "   ", accountName: "Yulei Liu") == "Yulei Liu")
    }
    @Test func bothBlankIsMe() {
        #expect(LocalUserName.resolve(override: "", accountName: "  ") == "Me")
    }
    @Test func trimsWhitespace() {
        #expect(LocalUserName.resolve(override: "  Sam  ", accountName: "x") == "Sam")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LocalUserNameTests`
Expected: FAIL — `cannot find 'LocalUserName'`.

- [ ] **Step 3: Implement `Sources/MeetingKit/LocalUserName.swift`**

```swift
import Foundation

/// Picks the display name for the local user ("me"). Pure so the system lookup
/// (`NSFullUserName()`) stays out of the testable logic — the caller passes it in.
public enum LocalUserName {
    /// A non-empty trimmed `override` wins; else a non-empty trimmed `accountName`;
    /// else the generic "Me".
    public static func resolve(override: String, accountName: String) -> String {
        let o = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return o }
        let a = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { return a }
        return "Me"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LocalUserNameTests` → PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/LocalUserName.swift Tests/MeetingKitTests/LocalUserNameTests.swift
git commit -m "feat: add LocalUserName resolver for the local user's display name"
```

---

## Task 2: `SpeakerLibrary.setLocalUserName`

**Files:**
- Modify: `Sources/MeetingKit/SpeakerLibrary.swift`
- Test: `Tests/MeetingKitTests/SpeakerLibraryLocalUserTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite struct SpeakerLibraryLocalUserTests {
    private func makeLib() -> SpeakerLibrary {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-lib-\(UUID().uuidString).json")
        return SpeakerLibrary(url: url)
    }

    @Test func renamesTheIsMeEntryAndKeepsVoiceprint() throws {
        let lib = makeLib()
        try lib.upsert(name: "Me", embedding: [1, 2, 3], isMe: true)
        try lib.upsert(name: "Sam", embedding: [4, 5, 6], isMe: false)
        try lib.setLocalUserName("Yulei Liu")
        let me = lib.me
        #expect(me?.name == "Yulei Liu")
        #expect(me?.isMe == true)
        #expect(me?.embedding == [1, 2, 3])
        // Non-me speakers untouched.
        #expect(lib.all().contains { $0.name == "Sam" && !$0.isMe })
    }

    @Test func noopWhenAlreadyCorrect() throws {
        let lib = makeLib()
        try lib.upsert(name: "Yulei Liu", embedding: [1], isMe: true)
        let before = lib.me?.updatedAt
        try lib.setLocalUserName("Yulei Liu")
        #expect(lib.me?.updatedAt == before)  // unchanged → not re-saved
    }

    @Test func noopWhenNotEnrolled() throws {
        let lib = makeLib()
        try lib.upsert(name: "Sam", embedding: [1], isMe: false)
        try lib.setLocalUserName("Yulei Liu")
        #expect(lib.me == nil)
        #expect(lib.all().count == 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SpeakerLibraryLocalUserTests`
Expected: FAIL — no member `setLocalUserName`.

- [ ] **Step 3: Implement — add to `Sources/MeetingKit/SpeakerLibrary.swift`** (after `rename(id:to:)`)

```swift
    /// Ensure the enrolled local user (the `isMe` entry) is named `name`, renaming it
    /// if different. Preserves the voiceprint + `isMe`. No-op if already correct or if
    /// the user isn't enrolled. Used to default/migrate "Me" to the account name.
    public func setLocalUserName(_ name: String) throws {
        guard let idx = speakers.firstIndex(where: { $0.isMe }) else { return }
        guard speakers[idx].name != name else { return }
        speakers[idx].name = name
        speakers[idx].updatedAt = Date()
        try save()
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SpeakerLibraryLocalUserTests` → PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerLibrary.swift Tests/MeetingKitTests/SpeakerLibraryLocalUserTests.swift
git commit -m "feat: SpeakerLibrary.setLocalUserName to name/migrate the local user"
```

---

## Task 3: `MeetingStore.deleteSpeakerMap`

**Files:**
- Modify: `Sources/MeetingKit/MeetingStore.swift`
- Test: `Tests/MeetingKitTests/MeetingStoreRetentionTests.swift` (extend)

- [ ] **Step 1: Write the failing test** (append to the existing `MeetingStoreRetentionTests` suite; it has `makeStore()` and a `seed(...)` helper that writes a full bundle)

```swift
    @Test func deleteSpeakerMapRemovesOnlyTheMap() throws {
        let (store, _) = try makeStore()
        let dir = try seed(store, id: "m", recordedAt: Date())
        try store.saveSpeakerMap(
            MeetingSpeakerMap(labelByCluster: ["S1": "Jane Doe"], embeddingByCluster: ["S1": [1]]),
            for: "m")
        #expect(store.speakerMap(for: "m") != nil)
        store.deleteSpeakerMap(for: "m")
        #expect(store.speakerMap(for: "m") == nil)
        // The rest of the bundle is intact.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("recording.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
        #expect(store.hasAudio(meetingID: "m") == true)
    }

    @Test func deleteSpeakerMapIsNoopWhenAbsent() throws {
        let (store, _) = try makeStore()
        try seed(store, id: "m", recordedAt: Date())
        store.deleteSpeakerMap(for: "m")  // no map written → must not throw/crash
        #expect(store.speakerMap(for: "m") == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MeetingStoreRetentionTests`
Expected: FAIL — no member `deleteSpeakerMap`.

- [ ] **Step 3: Implement — add to `Sources/MeetingKit/MeetingStore.swift`** (near `speakerMap(for:)`)

```swift
    /// Delete a meeting's per-meeting speaker map (`speakers.json`) so the next
    /// (re-)transcription re-recognizes speakers from scratch. Idempotent. Never
    /// touches the global speaker library (a root-level file, not in any bundle).
    public func deleteSpeakerMap(for meetingID: String) {
        let url = bundleURL(for: meetingID).appendingPathComponent("speakers.json")
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
```

(`bundleURL(for:)` is the existing non-creating path helper added with the retention feature.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter MeetingStoreRetentionTests` → PASS (all, incl. 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/MeetingStore.swift Tests/MeetingKitTests/MeetingStoreRetentionTests.swift
git commit -m "feat: MeetingStore.deleteSpeakerMap to reset per-meeting identifications"
```

---

## Task 4: MeetingProcessor — local-user label + reset map on (re-)process

**Files:**
- Modify: `Sources/MeetingKit/MeetingProcessor.swift`
- Test: `Tests/MeetingKitTests/SpeakerFuserTests.swift` (extend) + `Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `SpeakerFuserTests` (asserts the mic label is honored):

```swift
    @Test("mic segments carry the supplied local-user label")
    func micLabelHonored() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone)]
        let out = SpeakerFuser.fuse(
            segments: segs, timeline: SpeakerTimeline(samples: []),
            micDiarization: [], micLabels: [:], micLabel: "Yulei Liu")
        #expect(out.first?.speaker == "Yulei Liu")
    }
```

Append to `MeetingProcessorDiarizationTests` a test that a pre-existing speaker map is
removed when (re-)processing. Use that suite's existing store/recording/stub helpers; if
it lacks one, build a store + recording inline like the cancellation suite does. Concretely:

```swift
    @Test("re-processing deletes the prior per-meeting speaker map")
    func reprocessResetsSpeakerMap() async throws {
        let store = try MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-reproc-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: []))
        try store.save(recording)
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())
        // A stale map from a "previous" transcription.
        try store.saveSpeakerMap(
            MeetingSpeakerMap(labelByCluster: ["S1": "Jane Doe"], embeddingByCluster: ["S1": [1]]),
            for: meeting.id)

        let processor = MeetingProcessor(
            store: store, transcriber: StubTranscriber(), diarizer: StubDiarizer(),
            knownSpeakers: [], localUserName: "Yulei Liu")
        _ = try await processor.process(recording)

        // Stub diarizer produces no spans → no new map written → the stale one is gone.
        #expect(store.speakerMap(for: meeting.id) == nil)
    }
```

(If `StubTranscriber`/`StubDiarizer` aren't the exact stub names, use the ones the other MeetingProcessor tests use.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SpeakerFuserTests` then `swift test --filter "MeetingProcessor diarization"`
Expected: the fuser test passes already (micLabel param exists) OR fails to compile only if mislabeled; the reprocess test FAILS to compile — `MeetingProcessor.init` has no `localUserName:`.

- [ ] **Step 3: Implement — `Sources/MeetingKit/MeetingProcessor.swift`**

Add a stored property + init parameter:

```swift
    private let knownSpeakers: [KnownSpeaker]
    /// Display name for the local user's mic segments (defaults to the generic "Me").
    private let localUserName: String

    public init(
        store: MeetingStore,
        transcriber: Transcribing,
        diarizer: Diarizing = StubDiarizer(),
        knownSpeakers: [KnownSpeaker] = [],
        localUserName: String = "Me"
    ) {
        self.store = store
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.knownSpeakers = knownSpeakers
        self.localUserName = localUserName
    }
```

In `process(_:progress:)`, right after computing `micURL`/`systemURL` (before transcription), reset any prior identifications:

```swift
        // Re-transcription must re-recognize from scratch: drop the previous
        // per-meeting speaker map so stale labels don't carry over.
        store.deleteSpeakerMap(for: recording.meeting.id)
```

Change the fuse call to pass the local-user label:

```swift
        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: recording.timeline,
            micDiarization: outcome.spans,
            micLabels: micLabels,
            micLabel: localUserName
        )
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter SpeakerFuserTests` and `swift test --filter "MeetingProcessor"` → PASS.
Run: `swift build` → clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/MeetingProcessor.swift Tests/MeetingKitTests/SpeakerFuserTests.swift Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift
git commit -m "feat: label mic with the local-user name and reset speaker map on reprocess"
```

---

## Task 5: `AppSettings.localUserName`

**Files:**
- Modify: `Sources/MeetingAssistant/Settings.swift`

No unit test (UserDefaults-backed view-model; verified by build + running).

- [ ] **Step 1: Add the stored property + key + default**

In `AppSettings`, add a published property (mirror the `transcriptionWorkers` didSet pattern):

```swift
    /// Display name for the local user ("me") in transcripts and the UI. Defaults to
    /// the macOS account full name; editable. Blank falls back to the account name,
    /// then "Me".
    @Published var localUserName: String {
        didSet { defaults.set(localUserName, forKey: Keys.localUserName) }
    }
```

Add to `enum Keys`:

```swift
        static let localUserName = "localUserName"
```

In `init`, after the other property initializations:

```swift
        self.localUserName = LocalUserName.resolve(
            override: defaults.string(forKey: Keys.localUserName) ?? "",
            accountName: NSFullUserName())
```

(`LocalUserName` is in MeetingKit, already imported; `NSFullUserName()` is Foundation.)

- [ ] **Step 2: Build**

Run: `swift build` → clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/Settings.swift
git commit -m "feat: persist an editable localUserName setting (default account name)"
```

---

## Task 6: AppState wiring

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift`

No unit test (coordinator; verified by build + running).

- [ ] **Step 1: Sync the library name at launch**

At the end of `init()` (after the existing setup, e.g. after `rebuildSearchIndex()`), add:

```swift
        // Default/migrate the enrolled local user's name to the configured display
        // name (e.g. an old "Me" enrollment becomes "Yulei Liu").
        try? settings.speakerLibrary.setLocalUserName(settings.localUserName)
```

- [ ] **Step 2: Enroll under the local-user name**

Find the enrollment upsert:

```swift
            try settings.speakerLibrary.upsert(name: "Me", embedding: embedding, isMe: true)
```

Replace with:

```swift
            try settings.speakerLibrary.upsert(
                name: settings.localUserName, embedding: embedding, isMe: true)
```

- [ ] **Step 3: Pass the name into MeetingProcessor**

Find the processor construction:

```swift
        let processor = MeetingProcessor(
            store: store,
            transcriber: transcriber,
            diarizer: useDiar ? diarizer : StubDiarizer(),
            knownSpeakers: useDiar ? settings.speakerLibrary.all() : []
        )
```

Add the label:

```swift
        let processor = MeetingProcessor(
            store: store,
            transcriber: transcriber,
            diarizer: useDiar ? diarizer : StubDiarizer(),
            knownSpeakers: useDiar ? settings.speakerLibrary.all() : [],
            localUserName: settings.localUserName
        )
```

- [ ] **Step 4: Add an `applyLocalUserName()` the Settings UI calls on commit**

Add a method to `AppState` (near the enrollment/speaker methods). It normalizes the
already-typed `settings.localUserName` (blank → account name → "Me") and re-syncs the
enrolled library entry. Called **on commit** (not per keystroke), so the library file is
written once:

```swift
    /// Normalize + apply the local-user display name after the user finishes editing it:
    /// blank falls back to the account name, then "Me"; the enrolled library entry is
    /// re-synced so the voiceprint stays tied to the shown name. Future transcripts use
    /// the new name; past transcripts are unchanged.
    func applyLocalUserName() {
        settings.localUserName = LocalUserName.resolve(
            override: settings.localUserName, accountName: NSFullUserName())
        try? settings.speakerLibrary.setLocalUserName(settings.localUserName)
        objectWillChange.send()
    }
```

- [ ] **Step 5: Build**

Run: `swift build` → clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: apply the local-user name in enrollment, processing, and at launch"
```

---

## Task 7: UI — name highlight + editable field

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`
- Modify: `Sources/MeetingAssistant/SettingsView.swift`

No unit test (SwiftUI; verified by running).

- [ ] **Step 1: Highlight the local user by name in the transcript speakers row**

In `MainWindowView.swift`, the speaker rename row builds a chip:

```swift
            SpeakerChip(text: originalLabel, isMe: originalLabel == "Me").frame(
                width: 96, alignment: .leading)
```

Change the `isMe` test to compare against the configured name:

```swift
            SpeakerChip(text: originalLabel, isMe: originalLabel == state.settings.localUserName)
                .frame(width: 96, alignment: .leading)
```

If `state` isn't in scope in that subview, read the file: the row is built from a parent
that has `@EnvironmentObject var state: AppState`; thread `state.settings.localUserName`
in as a `let localUserName: String` on the row and compare `originalLabel == localUserName`.

- [ ] **Step 2: Add the editable name field to Settings → Speakers**

In `SettingsView.swift`, in the `speakersTab` (the `Form` with the "Your voice"/"Known
speakers" sections), add a section near the top:

```swift
            Section("Your name") {
                TextField(
                    "Display name",
                    text: Binding(
                        get: { state.settings.localUserName },
                        set: { state.settings.localUserName = $0 }  // cheap: per-keystroke UserDefaults only
                    )
                )
                .onSubmit { state.applyLocalUserName() }  // commit: normalize + re-sync library once
                Text("Shown instead of “Me” in transcripts. Defaults to your Mac account name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

(Read the file to match the exact `speakersTab` structure and indentation; place the new
`Section` as the first child of its `Form`.)

- [ ] **Step 3: Build + run**

Run: `swift build` → clean.
Run: `./Scripts/build-app.sh --run`. Verify: transcripts/new recordings label you by your
name (e.g. "Yulei Liu") not "Me"; the transcript speakers row highlights your name as
"you"; Settings → Speakers shows an editable name field; editing it and re-transcribing a
meeting uses the new name.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift Sources/MeetingAssistant/SettingsView.swift
git commit -m "feat: show + edit the local-user name in the UI (instead of Me)"
```

---

## Task 8: Full verification + requirement note

**Files:**
- Modify: `REQUIREMENTS.md`

- [ ] **Step 1: Full suite**

Run: `swift test`
Expected: all pass, including `LocalUserNameTests`, `SpeakerLibraryLocalUserTests`, the new
`MeetingStoreRetentionTests`/`SpeakerFuserTests`/`MeetingProcessor` cases.

- [ ] **Step 2: Add a requirement note**

In `REQUIREMENTS.md`, under the **Speakers** section (after R8/R9), add:

```
- **R8b — Local user named, not "Me".** The local user is labeled by an editable
  display name (defaulting to the macOS account full name) instead of "Me", in
  transcripts and the UI; an existing "Me" enrollment is migrated to that name.
- **R10c — Re-transcribe re-recognizes.** Re-transcribing a meeting clears its previous
  per-meeting speaker identifications and recognizes speakers afresh; the cross-meeting
  speaker library (R9) is preserved.
```

- [ ] **Step 3: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: record local-user naming (R8b) + re-transcribe re-recognition (R10c)"
```

---

## Self-review notes

- **Spec coverage:** name resolver (Task 1) ✓; library rename/migration (Task 2) ✓;
  delete-map (Task 3) ✓; fusion micLabel + reset-on-process + processor param (Task 4) ✓;
  setting w/ account-name default (Task 5) ✓; enrollment name + launch sync + processor
  wiring + apply-on-edit (Task 6) ✓; UI highlight + editable field (Task 7) ✓; verify +
  REQUIREMENTS (Task 8) ✓.
- **Placeholder scan:** none — concrete code throughout; the two UI edits note "read the
  file to match structure" only for indentation/scope threading, with the exact change given.
- **Type consistency:** `LocalUserName.resolve(override:accountName:)`,
  `SpeakerLibrary.setLocalUserName(_:)`, `MeetingStore.deleteSpeakerMap(for:)`,
  `MeetingProcessor.init(..., localUserName:)`, `SpeakerFuser.fuse(..., micLabel:)`,
  `AppSettings.localUserName`, `AppState.applyLocalUserName(_:)` — used consistently.
- **Out of scope (per spec):** rewriting past transcripts; iCloud/Apple-ID lookup;
  clearing the global library.
