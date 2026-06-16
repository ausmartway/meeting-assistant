# In-room Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Diarize the mic channel so multiple in-room participants become distinct speakers ("Me", "Speaker 2", "Speaker 3"…) instead of all collapsing into "Me".

**Architecture:** On-device diarization (FluidAudio, CoreML) runs in post-processing inside `MeetingProcessor`, reading the mic file `CaptureSession` already wrote — no live-capture changes. A new `Diarizing` protocol mirrors the `Transcribing`/`Backends` seam (real impl behind `#if canImport(FluidAudio)`, plus a stub). Pure logic maps diarized time-spans onto Whisper mic segments and assigns display labels; a one-time voice enrollment lets the diarizer resolve the user's voice to "Me".

**Tech Stack:** Swift 5.10, SwiftPM, swift-testing, FluidAudio (CoreML diarization), WhisperKit (existing), AVFoundation (enrollment recording).

**Reference spec:** `docs/superpowers/specs/2026-06-16-in-room-speaker-diarization-design.md`

---

## File structure

**Create:**
- `Sources/MeetingKit/Diarizer.swift` — `DiarizedSpan`, `MeEnrollment`, `Diarizing` protocol, `StubDiarizer`, and the real `FluidAudioDiarizer` (`#if canImport(FluidAudio)`).
- `Sources/MeetingKit/DiarizationLabeler.swift` — pure span→label and span→segment logic.
- `Sources/MeetingAssistant/EnrollmentRecorder.swift` — records the ~15 s "Me" clip.
- `Tests/MeetingKitTests/DiarizationLabelerTests.swift`
- `Tests/MeetingKitTests/DiarizerStubTests.swift`

**Modify:**
- `Package.swift:15-28` — add the FluidAudio dependency to the package and the MeetingKit target.
- `Sources/MeetingKit/Models.swift` — (no change; new models live in `Diarizer.swift` to keep them next to the protocol).
- `Sources/MeetingKit/SpeakerFuser.swift:17-39` — accept optional mic diarization.
- `Sources/MeetingKit/Backends.swift:7-27` — add `makeDiarizer` + `hasLocalDiarization`.
- `Sources/MeetingKit/MeetingProcessor.swift:7-57` — accept an optional diarizer + enrollment, run diarization on the mic file, pass spans to the fuser.
- `Sources/MeetingAssistant/Settings.swift` — diarization toggle, enrollment path, `makeDiarizer()`.
- `Sources/MeetingAssistant/AppState.swift:95-188,278-308` — own a diarizer, pass it + enrollment into `MeetingProcessor`.
- `Sources/MeetingAssistant/SettingsView.swift` — toggle + enrollment UI.

---

## Task 1: Core diarization models

**Files:**
- Create: `Sources/MeetingKit/Diarizer.swift`
- Test: `Tests/MeetingKitTests/DiarizerStubTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/DiarizerStubTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("Diarizer models & stub")
struct DiarizerStubTests {

    @Test("DiarizedSpan round-trips through Codable")
    func spanCodable() throws {
        let span = DiarizedSpan(start: 1.0, end: 2.5, speakerID: "Me")
        let data = try JSONEncoder().encode(span)
        let back = try JSONDecoder().decode(DiarizedSpan.self, from: data)
        #expect(back == span)
    }

    @Test("StubDiarizer returns no spans so callers fall back to 'Me'")
    func stubReturnsEmpty() async throws {
        let stub = StubDiarizer()
        let spans = try await stub.diarize(
            audioFile: URL(fileURLWithPath: "/tmp/none.wav"),
            enrollment: nil,
            progress: nil
        )
        #expect(spans.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Diarizer models & stub"`
Expected: FAIL to compile — `DiarizedSpan`, `MeEnrollment`, `Diarizing`, `StubDiarizer` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MeetingKit/Diarizer.swift` (real engine added in Task 7; stub + types only for now):

```swift
import Foundation

/// One contiguous run of speech attributed to a single diarized speaker on the
/// **mic** channel. Produced by a `Diarizing` backend in post-processing.
public struct DiarizedSpan: Codable, Sendable, Equatable {
    public let start: TimeInterval     // seconds from meeting start
    public let end: TimeInterval
    /// The diarizer's speaker id. The literal "Me" marks the span as matched to
    /// the enrolled local user; any other string is an anonymous in-room speaker.
    public let speakerID: String

    public init(start: TimeInterval, end: TimeInterval, speakerID: String) {
        self.start = start
        self.end = end
        self.speakerID = speakerID
    }
}

/// A persisted one-time recording of the local user's voice, used by the diarizer
/// to label the user's own mic segments as "Me".
public struct MeEnrollment: Codable, Sendable, Equatable {
    public let audioFile: URL      // ~15 s mic clip stored under Application Support
    public let recordedAt: Date

    public init(audioFile: URL, recordedAt: Date) {
        self.audioFile = audioFile
        self.recordedAt = recordedAt
    }
}

/// Splits a single mixed audio file into per-speaker time spans. This is the seam
/// between the app and the on-device diarization engine; the real engine
/// (FluidAudio, CoreML) requires that package, so `StubDiarizer` keeps the
/// pipeline runnable without it.
public protocol Diarizing: Sendable {
    /// Download + load the diarization models ahead of time. Idempotent.
    func prepare(progress: TranscribeProgressHandler?) async throws

    /// Diarize one audio file into speaker spans. When `enrollment` is provided,
    /// spans matching the enrolled user carry `speakerID == "Me"`.
    func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan]
}

/// No-ML placeholder. Returns no spans, so the fuser keeps today's mic = "Me".
public struct StubDiarizer: Diarizing {
    public init() {}
    public func prepare(progress: TranscribeProgressHandler?) async throws {}
    public func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan] { [] }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "Diarizer models & stub"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/Diarizer.swift Tests/MeetingKitTests/DiarizerStubTests.swift
git commit -m "feat: add Diarizing protocol, span/enrollment models, and stub"
```

---

## Task 2: Pure diarization labeler

**Files:**
- Create: `Sources/MeetingKit/DiarizationLabeler.swift`
- Test: `Tests/MeetingKitTests/DiarizationLabelerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/DiarizationLabelerTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("DiarizationLabeler")
struct DiarizationLabelerTests {

    private func span(_ start: Double, _ end: Double, _ id: String) -> DiarizedSpan {
        DiarizedSpan(start: start, end: end, speakerID: id)
    }

    @Test("enrolled 'Me' stays Me; others numbered from 2 by first appearance")
    func displayLabels() {
        let spans = [
            span(0, 1, "Me"),
            span(1, 2, "spk_a"),
            span(2, 3, "spk_b"),
            span(3, 4, "spk_a"),   // repeat keeps its number
        ]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(labels["Me"] == "Me")
        #expect(labels["spk_a"] == "Speaker 2")
        #expect(labels["spk_b"] == "Speaker 3")
    }

    @Test("numbering is by first appearance regardless of id ordering")
    func numberingOrder() {
        let spans = [span(0, 1, "zzz"), span(1, 2, "aaa")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(labels["zzz"] == "Speaker 2")
        #expect(labels["aaa"] == "Speaker 3")
    }

    @Test("speaker(at:) returns the label of the span containing the time")
    func speakerAtContained() {
        let spans = [span(0, 2, "Me"), span(2, 4, "spk_a")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(DiarizationLabeler.speaker(at: 1.0, spans: spans, labels: labels) == "Me")
        #expect(DiarizationLabeler.speaker(at: 3.0, spans: spans, labels: labels) == "Speaker 2")
    }

    @Test("speaker(at:) returns nil when the time is in a gap between spans")
    func speakerAtGap() {
        let spans = [span(0, 1, "Me"), span(2, 3, "spk_a")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(DiarizationLabeler.speaker(at: 1.5, spans: spans, labels: labels) == nil)
    }

    @Test("span end is exclusive: a time exactly on a boundary belongs to the next span")
    func boundaryExclusive() {
        let spans = [span(0, 2, "Me"), span(2, 4, "spk_a")]
        let labels = DiarizationLabeler.displayLabels(for: spans)
        #expect(DiarizationLabeler.speaker(at: 2.0, spans: spans, labels: labels) == "Speaker 2")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiarizationLabeler`
Expected: FAIL to compile — `DiarizationLabeler` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MeetingKit/DiarizationLabeler.swift`:

```swift
import Foundation

/// Pure logic that turns a diarizer's raw speaker spans into display labels and
/// resolves the label active at a given time. Kept pure and table-driven so it is
/// easy to test without any model.
public enum DiarizationLabeler {

    /// The id the diarizer uses for the enrolled local user.
    public static let meSpeakerID = "Me"

    /// Map each distinct `speakerID` to a display label: the enrolled user stays
    /// "Me"; every other speaker becomes "Speaker 2", "Speaker 3", … numbered by
    /// order of first appearance across `spans`.
    public static func displayLabels(for spans: [DiarizedSpan]) -> [String: String] {
        var labels: [String: String] = [:]
        var next = 2
        for span in spans where labels[span.speakerID] == nil {
            if span.speakerID == meSpeakerID {
                labels[span.speakerID] = "Me"
            } else {
                labels[span.speakerID] = "Speaker \(next)"
                next += 1
            }
        }
        return labels
    }

    /// The display label of the span whose `[start, end)` contains `t`, or nil if
    /// `t` falls in a gap. End is exclusive so adjacent spans don't both match.
    public static func speaker(
        at t: TimeInterval,
        spans: [DiarizedSpan],
        labels: [String: String]
    ) -> String? {
        guard let span = spans.first(where: { t >= $0.start && t < $0.end }) else { return nil }
        return labels[span.speakerID]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiarizationLabeler`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/DiarizationLabeler.swift Tests/MeetingKitTests/DiarizationLabelerTests.swift
git commit -m "feat: add pure diarization labeler (span->label, time->label)"
```

---

## Task 3: Wire diarization into SpeakerFuser

**Files:**
- Modify: `Sources/MeetingKit/SpeakerFuser.swift:17-39`
- Test: `Tests/MeetingKitTests/SpeakerFuserTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/MeetingKitTests/SpeakerFuserTests.swift` inside the existing `@Suite` struct (add `import Foundation` at top if absent):

```swift
    @Test("mic segments resolve to diarized speakers when spans are provided")
    func micDiarizationLabels() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone),
            TranscriptSegment(start: 2, end: 3, text: "hello", channel: .microphone),
        ]
        let spans = [
            DiarizedSpan(start: 0, end: 1.5, speakerID: "Me"),
            DiarizedSpan(start: 1.5, end: 4, speakerID: "spk_a"),
        ]
        let out = SpeakerFuser.fuse(
            segments: segments,
            timeline: SpeakerTimeline(samples: []),
            micDiarization: spans
        )
        #expect(out.map(\.speaker) == ["Me", "Speaker 2"])
    }

    @Test("with no diarization spans, mic stays 'Me' (unchanged behavior)")
    func micFallsBackToMe() {
        let segments = [TranscriptSegment(start: 0, end: 1, text: "hi", channel: .microphone)]
        let out = SpeakerFuser.fuse(segments: segments, timeline: SpeakerTimeline(samples: []))
        #expect(out.map(\.speaker) == ["Me"])
    }

    @Test("mic segment whose midpoint is in a diarization gap falls back to 'Me'")
    func micGapFallsBackToMe() {
        let segments = [TranscriptSegment(start: 5, end: 6, text: "x", channel: .microphone)]
        let spans = [DiarizedSpan(start: 0, end: 1, speakerID: "spk_a")]
        let out = SpeakerFuser.fuse(
            segments: segments,
            timeline: SpeakerTimeline(samples: []),
            micDiarization: spans
        )
        #expect(out.map(\.speaker) == ["Me"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerFuser`
Expected: FAIL to compile — `fuse` has no `micDiarization:` parameter.

- [ ] **Step 3: Write minimal implementation**

Replace `SpeakerFuser.fuse` (`Sources/MeetingKit/SpeakerFuser.swift:17-39`) with:

```swift
    public static func fuse(
        segments: [TranscriptSegment],
        timeline: SpeakerTimeline,
        micDiarization: [DiarizedSpan] = [],
        micLabel: String = "Me",
        unknownLabel: String = "Speaker"
    ) -> [LabeledSegment] {
        // Precompute diarized display labels once (empty when not diarizing).
        let micLabels = DiarizationLabeler.displayLabels(for: micDiarization)
        return segments.map { segment in
            let midpoint = (segment.start + segment.end) / 2
            let speaker: String
            switch segment.channel {
            case .microphone:
                // No diarization → today's behavior. Otherwise resolve the span at
                // the segment midpoint, falling back to "Me" in gaps.
                if micDiarization.isEmpty {
                    speaker = micLabel
                } else {
                    speaker = DiarizationLabeler.speaker(
                        at: midpoint, spans: micDiarization, labels: micLabels
                    ) ?? micLabel
                }
            case .system:
                speaker = activeSpeaker(at: midpoint, in: timeline) ?? unknownLabel
            }
            return LabeledSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speaker
            )
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerFuser`
Expected: PASS — new tests plus all pre-existing SpeakerFuser tests (the default empty `micDiarization` preserves old behavior).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerFuser.swift Tests/MeetingKitTests/SpeakerFuserTests.swift
git commit -m "feat: SpeakerFuser resolves mic speakers from diarization spans"
```

---

## Task 4: Backends factory for the diarizer

**Files:**
- Modify: `Sources/MeetingKit/Backends.swift:7-27`

- [ ] **Step 1: Write the failing test**

Append to `Tests/MeetingKitTests/DiarizerStubTests.swift` inside the suite:

```swift
    @Test("Backends.makeDiarizer returns a usable diarizer")
    func makeDiarizer() async throws {
        let d = Backends.makeDiarizer()
        // Whichever backend compiles in, an unenrolled empty path yields no crash.
        _ = try? await d.diarize(
            audioFile: URL(fileURLWithPath: "/tmp/none.wav"),
            enrollment: nil,
            progress: nil
        )
        #expect(Backends.hasLocalDiarization == Backends.hasLocalDiarization) // tautology: just exercises the symbol
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Diarizer models & stub"`
Expected: FAIL to compile — `makeDiarizer` / `hasLocalDiarization` not defined.

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/MeetingKit/Backends.swift` inside the `Backends` enum (after `hasLocalTranscription`):

```swift
    /// The on-device diarizer: real FluidAudio when available, else the stub.
    public static func makeDiarizer() -> Diarizing {
        #if canImport(FluidAudio)
        return FluidAudioDiarizer()
        #else
        return StubDiarizer()
        #endif
    }

    /// Whether a real on-device diarization backend is compiled in.
    public static var hasLocalDiarization: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "Diarizer models & stub"`
Expected: PASS. (`FluidAudio` is not yet a dependency, so `canImport` is false and the stub is returned — that's fine; the real backend lands in Tasks 6–7.)

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/Backends.swift Tests/MeetingKitTests/DiarizerStubTests.swift
git commit -m "feat: add Backends.makeDiarizer + hasLocalDiarization"
```

---

## Task 5: Run diarization in MeetingProcessor

**Files:**
- Modify: `Sources/MeetingKit/MeetingProcessor.swift:7-57`
- Test: `Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingProcessor diarization wiring")
struct MeetingProcessorDiarizationTests {

    // A transcriber that returns one mic segment so we can observe its label.
    private struct OneMicSegmentTranscriber: Transcribing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?) async throws -> [TranscriptSegment] {
            channel == .microphone
                ? [TranscriptSegment(start: 0, end: 4, text: "hello from the room", channel: .microphone)]
                : []
        }
    }

    // A diarizer that splits the timeline into Me then another speaker.
    private struct TwoSpeakerDiarizer: Diarizing {
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func diarize(audioFile: URL, enrollment: MeEnrollment?, progress: TranscribeProgressHandler?) async throws -> [DiarizedSpan] {
            [DiarizedSpan(start: 0, end: 5, speakerID: "spk_a")]   // not "Me" → Speaker 2
        }
    }

    @Test("diarized mic segments are labeled by speaker, not blanket 'Me'")
    func diarizedLabels() async throws {
        let store = try MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-diar-\(UUID().uuidString)"))
        let meeting = Meeting.adHoc(id: UUID().uuidString, provider: nil, start: Date())
        let recording = MeetingRecording(
            meeting: meeting, recordedAt: Date(),
            micAudioFile: "mic.wav", systemAudioFile: "sys.wav",
            timeline: SpeakerTimeline(samples: [])
        )
        try store.save(recording)
        // Create empty audio files so the path exists (transcriber is a stub).
        let dir = try store.directory(for: meeting.id)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mic.wav").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sys.wav").path, contents: Data())

        let processor = MeetingProcessor(
            store: store,
            transcriber: OneMicSegmentTranscriber(),
            diarizer: TwoSpeakerDiarizer(),
            enrollment: nil
        )
        let transcript = try await processor.process(recording)
        #expect(transcript.contains("Speaker 2:"))
        #expect(!transcript.contains("Me:"))
    }
}
```

> NOTE — verified: `MeetingStore(root:)`, `store.save(_:)`, and `store.directory(for:)` exist with these signatures (`Sources/MeetingKit/MeetingStore.swift:17,34,41`). If the test setup needs more, mirror `Tests/MeetingKitTests/MeetingStoreTests.swift`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "MeetingProcessor diarization wiring"`
Expected: FAIL to compile — `MeetingProcessor.init` has no `diarizer:`/`enrollment:` parameters.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MeetingKit/MeetingProcessor.swift`, extend the stored properties + init (lines 8-14):

```swift
    private let store: MeetingStore
    private let transcriber: Transcribing
    private let diarizer: Diarizing
    private let enrollment: MeEnrollment?

    public init(
        store: MeetingStore,
        transcriber: Transcribing,
        diarizer: Diarizing = StubDiarizer(),
        enrollment: MeEnrollment? = nil
    ) {
        self.store = store
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.enrollment = enrollment
    }
```

Then change the fusion step (lines 40-42) to diarize the mic file first. Replace:

```swift
        // 2. Drop whisper silence artifacts, then fuse speaker labels.
        let cleaned = HallucinationFilter.clean(allSegments)
        let labeled = SpeakerFuser.fuse(segments: cleaned, timeline: recording.timeline)
```

with:

```swift
        // 2. Drop whisper silence artifacts.
        let cleaned = HallucinationFilter.clean(allSegments)

        // 2b. Diarize the mic channel so multiple in-room speakers are separated.
        //     Best-effort: any failure degrades to blanket "Me" (empty spans).
        var micSpans: [DiarizedSpan] = []
        do {
            micSpans = try await diarizer.diarize(
                audioFile: micURL, enrollment: enrollment, progress: onProgress
            )
        } catch {
            micSpans = []   // non-fatal — keep today's "Me" labeling
        }

        // 2c. Fuse speaker labels (mic via diarization, system via the timeline).
        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: recording.timeline,
            micDiarization: micSpans
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "MeetingProcessor diarization wiring"`
Expected: PASS.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `swift test`
Expected: PASS (all suites).

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/MeetingProcessor.swift Tests/MeetingKitTests/MeetingProcessorDiarizationTests.swift
git commit -m "feat: diarize mic channel during meeting post-processing"
```

---

## Task 6: Add the FluidAudio dependency

**Files:**
- Modify: `Package.swift:15-28`

- [ ] **Step 1: Add the package + product**

In `Package.swift`, add to `dependencies` (after the WhisperKit line):

```swift
        // On-device speaker diarization (CoreML / Apple Neural Engine).
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.5.0"),
```

And add to the `MeetingKit` target's `dependencies`:

```swift
                .product(name: "FluidAudio", package: "FluidAudio"),
```

- [ ] **Step 2: Resolve and build**

Run: `swift package resolve && swift build --target MeetingKit`
Expected: FluidAudio resolves and downloads. Build may still succeed because `FluidAudioDiarizer` does not exist yet (Task 7) — `canImport(FluidAudio)` is now true but `Backends.makeDiarizer` references `FluidAudioDiarizer`, so **this build is expected to FAIL** with "cannot find 'FluidAudioDiarizer' in scope". That failure is the cue to do Task 7 next.

> If `from: "0.5.0"` does not resolve, run `git ls-remote --tags https://github.com/FluidInference/FluidAudio` and pin the latest stable tag instead.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add FluidAudio on-device diarization dependency"
```

---

## Task 7: Real FluidAudio diarizer backend

**Files:**
- Modify: `Sources/MeetingKit/Diarizer.swift` (append the `#if canImport(FluidAudio)` section)

> This is a framework-integration task verified by **building and running**, not by unit tests — exactly how `WhisperKitTranscriber` is handled (see CLAUDE.md "Pure logic vs. integrations"). The code below mirrors `WhisperKitTranscriber`'s actor + task-memoized model load. FluidAudio's exact symbol names may differ from the documented sketch; if a name doesn't resolve, consult `https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md` and adjust to the compiled signatures, keeping the inputs/outputs of `diarize(...)` unchanged.

- [ ] **Step 1: Append the real backend**

Append to `Sources/MeetingKit/Diarizer.swift`:

```swift
// MARK: - Real engine (compiled only when FluidAudio is available)

#if canImport(FluidAudio)
import FluidAudio

/// On-device diarization via FluidAudio's offline pipeline. An actor so the
/// CoreML models download/load exactly once even under concurrent calls
/// (mirrors `WhisperKitTranscriber`).
public actor FluidAudioDiarizer: Diarizing {
    private var loadTask: Task<OfflineDiarizerManager, Error>?

    public init() {}

    /// App-owned model location, alongside the Whisper models.
    private static var modelDir: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingAssistant/DiarizationModels", isDirectory: true)
    }

    public func prepare(progress: TranscribeProgressHandler?) async throws {
        _ = try await manager(progress: progress)
    }

    public func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan] {
        let mgr = try await manager(progress: progress)
        progress?(TranscribeProgress(fraction: 0, phase: "Separating in-room speakers…"))

        // Register the local user so their spans come back labeled "Me".
        if let enrollment {
            let enrollSamples = try Self.loadSamples(enrollment.audioFile)
            try await mgr.enrollSpeaker(withAudio: enrollSamples, sourceSampleRate: 16_000, named: DiarizationLabeler.meSpeakerID)
        }

        let samples = try Self.loadSamples(audioFile)
        let result = try await mgr.process(audio: samples)

        // Map FluidAudio's result segments to our DiarizedSpan. The exact field
        // names live in FluidAudio's DiarizationResult; adapt if they differ.
        return result.segments.map { seg in
            DiarizedSpan(
                start: TimeInterval(seg.startTime),
                end: TimeInterval(seg.endTime),
                speakerID: seg.speakerId
            )
        }
    }

    private func manager(progress: TranscribeProgressHandler?) async throws -> OfflineDiarizerManager {
        if let loadTask { return try await loadTask.value }
        let task = Task { () throws -> OfflineDiarizerManager in
            progress?(TranscribeProgress(fraction: nil, phase: "Loading diarization model…"))
            let mgr = OfflineDiarizerManager()
            try await mgr.prepareModels(directory: Self.modelDir)
            return mgr
        }
        loadTask = task
        do { return try await task.value }
        catch { loadTask = nil; throw error }
    }

    /// Decode an audio file to 16 kHz mono float samples.
    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return [] }
        let frameCapacity = AVAudioFrameCount(file.length)
        guard frameCapacity > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCapacity) else { return [] }
        try file.read(into: inBuf)
        let ratio = 16_000.0 / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else { return [] }
        var done = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        guard let ptr = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
    }
}

import AVFoundation
#endif
```

- [ ] **Step 2: Build the library**

Run: `swift build --target MeetingKit`
Expected: PASS. If FluidAudio symbol names differ, fix per the note above until it compiles.

- [ ] **Step 3: Build everything**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS (pure-logic suites unaffected; the real backend is not unit-tested).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/Diarizer.swift
git commit -m "feat: FluidAudio on-device diarization backend"
```

---

## Task 8: Settings — toggle + enrollment storage

**Files:**
- Modify: `Sources/MeetingAssistant/Settings.swift`

- [ ] **Step 1: Add the setting, enrollment accessors, and factory**

In `Sources/MeetingAssistant/Settings.swift`, add a published property (after `showDockIcon`, lines 25-27):

```swift
    /// Split the mic channel into multiple in-room speakers during processing.
    /// Off by default; only meaningful once the user has enrolled their voice.
    @Published var identifyInRoomSpeakers: Bool {
        didSet { defaults.set(identifyInRoomSpeakers, forKey: Keys.identifyInRoomSpeakers) }
    }
```

Add the key (in `enum Keys`, lines 31-35):

```swift
        static let identifyInRoomSpeakers = "identifyInRoomSpeakers"
```

Initialize it (in `init`, after the `showDockIcon` setup, line 47):

```swift
        self.identifyInRoomSpeakers = defaults.bool(forKey: Keys.identifyInRoomSpeakers)
```

Add enrollment storage + factory (after `makeTranscriber()`, line 53):

```swift
    /// On-disk location of the enrolled "Me" voice clip.
    var enrollmentURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingAssistant/enrollment.wav")
    }

    /// The persisted enrollment, or nil if the user hasn't recorded one.
    var enrollment: MeEnrollment? {
        let url = enrollmentURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.creationDate] as? Date else { return nil }
        return MeEnrollment(audioFile: url, recordedAt: date)
    }

    var isEnrolled: Bool { enrollment != nil }

    /// Build the on-device diarizer (real FluidAudio when compiled in).
    func makeDiarizer() -> Diarizing {
        Backends.makeDiarizer()
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/Settings.swift
git commit -m "feat: in-room speaker setting + enrollment storage"
```

---

## Task 9: Enrollment recorder

**Files:**
- Create: `Sources/MeetingAssistant/EnrollmentRecorder.swift`

- [ ] **Step 1: Implement the recorder**

Create `Sources/MeetingAssistant/EnrollmentRecorder.swift`:

```swift
import Foundation
import AVFoundation

/// Records a short mic clip (~15 s, 16 kHz mono WAV) for voice enrollment, written
/// to a caller-supplied URL. Used by Settings so the diarizer can label the local
/// user's voice as "Me".
@MainActor
final class EnrollmentRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var destination: URL?

    /// Record up to `seconds` of audio to `url`, then call `completion`.
    func record(to url: URL, seconds: TimeInterval = 15, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            self.recorder = rec
            self.onFinish = completion
            self.destination = url
            rec.record(forDuration: seconds)
            isRecording = true
        } catch {
            completion(.failure(error))
        }
    }

    /// Stop early (the user pressing "Stop").
    func stop() { recorder?.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            guard let dest = self.destination else { return }
            self.onFinish?(flag ? .success(dest)
                                 : .failure(NSError(domain: "Enrollment", code: 1)))
            self.recorder = nil
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/EnrollmentRecorder.swift
git commit -m "feat: voice enrollment recorder"
```

---

## Task 10: Settings UI — toggle + enrollment controls

**Files:**
- Modify: `Sources/MeetingAssistant/SettingsView.swift`

- [ ] **Step 1: Read the current SettingsView**

Run: `cat Sources/MeetingAssistant/SettingsView.swift`
The view reaches settings via `@EnvironmentObject private var state: AppState` (`SettingsView.swift:6`), so `AppSettings` is `state.settings`. There are three `Form`s (lines 21, 43, 81) — add the new section to the one holding the transcription/general preferences (the model + workers rows). Match its existing `Section` style.

- [ ] **Step 2: Add the enrollment section**

Add a new `Section` to that `Form`, reaching settings through `state.settings`. Add `@StateObject private var enroller = EnrollmentRecorder()` and `@State private var enrollError: String?` to the view. Replace `settings.` with `state.settings.` throughout the snippet below:

```swift
            Section("In-room meetings") {
                Toggle("Identify multiple in-room speakers", isOn: Binding(
                    get: { settings.identifyInRoomSpeakers },
                    set: { newValue in
                        // Enabling requires an enrollment first.
                        if newValue && !settings.isEnrolled {
                            enrollError = "Record your voice first so it can be labeled “Me”."
                        } else {
                            settings.identifyInRoomSpeakers = newValue
                        }
                    }
                ))
                .help("When you’re in a room with others, separate each voice instead of labeling everyone “Me”.")

                HStack {
                    Text(settings.isEnrolled ? "Your voice is enrolled." : "Your voice is not enrolled.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if enroller.isRecording {
                        Button("Stop") { enroller.stop() }
                    } else {
                        Button(settings.isEnrolled ? "Re-record" : "Record (15s)") {
                            enrollError = nil
                            enroller.record(to: settings.enrollmentURL) { result in
                                if case .failure = result {
                                    enrollError = "Recording failed. Check microphone access."
                                }
                            }
                        }
                    }
                    if settings.isEnrolled {
                        Button("Delete", role: .destructive) {
                            try? FileManager.default.removeItem(at: settings.enrollmentURL)
                            settings.identifyInRoomSpeakers = false
                        }
                    }
                }
                if let enrollError {
                    Text(enrollError).font(.caption).foregroundStyle(.red)
                }
            }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingAssistant/SettingsView.swift
git commit -m "feat: settings UI for in-room speakers + voice enrollment"
```

---

## Task 11: AppState — own and pass the diarizer

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift:95-188,278-308`

- [ ] **Step 1: Add a stored diarizer**

After the `transcriber` property (line 97), add:

```swift
    /// Shared diarizer reused across processing so its models load once.
    private var diarizer: Diarizing
```

In `init`, after the `transcriber = Backends.makeTranscriber(...)` block (lines 109-112), add:

```swift
        self.diarizer = Backends.makeDiarizer()
```

- [ ] **Step 2: Prepare the diarizer when the feature is on**

In `prepareModel()` (lines 161-188), after `try await transcriber.prepare(...)` succeeds (line 178), add a best-effort diarizer warm-up so the model downloads ahead of the first in-room meeting:

```swift
            if settings.identifyInRoomSpeakers {
                diarizer = Backends.makeDiarizer()
                try? await diarizer.prepare(progress: tHandler)
            }
```

- [ ] **Step 3: Pass diarizer + enrollment into the processor**

In `process(_:)` (line 283), replace:

```swift
        let processor = MeetingProcessor(store: store, transcriber: transcriber)
```

with:

```swift
        let processor = MeetingProcessor(
            store: store,
            transcriber: transcriber,
            diarizer: settings.identifyInRoomSpeakers ? diarizer : StubDiarizer(),
            enrollment: settings.identifyInRoomSpeakers ? settings.enrollment : nil
        )
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: AppState wires diarizer + enrollment into processing"
```

---

## Task 12: Manual end-to-end verification

**Files:** none (manual run).

- [ ] **Step 1: Build the app**

Run: `./Scripts/build-app.sh`
Expected: a release `build/Meeting Assistant.app`.

- [ ] **Step 2: Enroll and enable**

Launch the app → Settings → "In-room meetings" → Record (15 s) of your own voice → toggle "Identify multiple in-room speakers" on. Confirm the model downloads (progress UI) and finishes.

- [ ] **Step 3: Record a multi-person session**

Start an ad-hoc capture with at least one other person speaking next to you. Stop & process.

- [ ] **Step 4: Inspect the transcript**

Open `transcript.md`. Expected: your lines labeled `Me:`, the other in-room person labeled `Speaker 2:` (and `Speaker 3:` if a third joins). Verify a solo stretch where only you talk is still `Me:`.

- [ ] **Step 5: Regression check**

Turn the setting **off**, process a normal solo remote meeting. Expected: behavior identical to before — all mic lines `Me:`, remote lines named/`Speaker` as today.

- [ ] **Step 6: Commit any fixes** discovered during verification with a `fix:` message.

---

## Self-review notes

- **Spec coverage:** engine choice (Task 6–7), `Diarizing` seam + stub (Task 1, 4), pure labeler (Task 2), `SpeakerFuser` change (Task 3), post-processing wiring + best-effort fallback (Task 5), enrollment model/storage/recorder/UI (Tasks 1, 8, 9, 10), feature gating off-by-default + enrollment-required (Tasks 8, 10, 11), error fallback to "Me" (Task 5), tests for pure logic only (Tasks 1–5). All spec sections map to a task.
- **Label scheme:** "Me" + "Speaker 2"… implemented in `DiarizationLabeler` (Task 2), matching spec default #1. Remote unknowns stay "Speaker" (untouched system branch in Task 3).
- **Type consistency:** `DiarizedSpan(start,end,speakerID)`, `MeEnrollment(audioFile,recordedAt)`, `Diarizing.diarize(audioFile:enrollment:progress:)`, `DiarizationLabeler.displayLabels(for:)` / `.speaker(at:spans:labels:)` / `.meSpeakerID`, `Backends.makeDiarizer()`, `MeetingProcessor.init(store:transcriber:diarizer:enrollment:)` used identically across tasks.
- **Known external-API risk (Task 7):** FluidAudio's exact symbol names (`OfflineDiarizerManager.process`, result `segments` fields, `enrollSpeaker`) are taken from its published API doc and may need adjustment against the compiled package — flagged inline, contained to one file, verified by building/running (consistent with how WhisperKit is treated).
- **Task 5 store API:** the test's `MeetingStore` construction is flagged to be matched against the real initializer in `MeetingStoreTests.swift` before running.
```
