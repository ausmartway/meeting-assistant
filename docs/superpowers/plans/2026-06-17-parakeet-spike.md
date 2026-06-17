# Parakeet (FluidAudio) transcription spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add NVIDIA Parakeet (via the already-linked FluidAudio SDK) as a second on-device transcription backend, selectable from a user-facing Settings picker, plus a CLI benchmark to compare it head-to-head against WhisperKit on real recordings.

**Architecture:** A new `FluidAudioTranscriber` actor implements the existing `Transcribing` protocol using FluidAudio's `AsrManager`/`AsrModels` Parakeet API. A pure `ParakeetSegmentBuilder` turns Parakeet's per-token timings into `[TranscriptSegment]` (unit-tested). A `TranscriptionEngine` enum + a Settings picker route `Backends.makeTranscriber(...)` to either engine. WhisperKit stays the default and the Mandarin fallback. A `TranscribeBench` executable measures RTFx for both.

**Tech Stack:** Swift 6, FluidAudio 0.15.3 (already a dependency, `from: "0.5.0"`), WhisperKit, swift-testing.

---

## Verified FluidAudio 0.15.3 ASR API (authoritative — from the resolved checkout)

```swift
import FluidAudio

// Models (download is automatic on first load; cached under Application Support):
public enum AsrModelVersion: Sendable { case v2; case v3; /* + tdtCtc110m, tdtJa */ }
public struct AsrModels: Sendable {
    public static func downloadAndLoad(
        to directory: URL? = nil,
        configuration: MLModelConfiguration? = nil,
        version: AsrModelVersion = .v3,
        encoderPrecision: ParakeetEncoderPrecision = .int8,
        encoderComputeUnits: MLComputeUnits? = nil,
        progressHandler: DownloadUtils.ProgressHandler? = nil
    ) async throws -> AsrModels
}

public actor AsrManager {
    public init(config: ASRConfig = .default, models: AsrModels? = nil)
    public func loadModels(_ models: AsrModels) async throws
    public func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
}

public struct TdtDecoderState: Sendable { public init(decoderLayers: Int = 2) throws }

public struct ASRResult: Codable, Sendable {
    public let text: String
    public let confidence: Float
    public let duration: TimeInterval
    public let tokenTimings: [TokenTiming]?
    // ...
}
public struct TokenTiming: Codable, Sendable {
    public let token: String
    public let tokenId: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float
}
```

- `.v2` = English Parakeet-TDT-0.6B (use for this English-first spike). `.v3` = multilingual.
- `transcribe(_ url:)` accepts a file URL directly (resamples internally).
- License: FluidAudio Apache-2.0; Parakeet CoreML weights CC-BY-4.0 (commercial-OK **with attribution** to NVIDIA + FluidInference).
- Min macOS 14 — no deployment-floor change.

---

## File Structure

- **Create** `Sources/MeetingKit/ParakeetSegmentBuilder.swift` — pure: token timings → `[TranscriptSegment]`. No FluidAudio import (testable everywhere).
- **Create** `Tests/MeetingKitTests/ParakeetSegmentBuilderTests.swift` — unit tests for the builder.
- **Modify** `Sources/MeetingKit/Transcriber.swift` — add `TranscriptionEngine` enum; add `FluidAudioTranscriber` actor (under `#if canImport(FluidAudio)`).
- **Modify** `Sources/MeetingKit/Backends.swift` — `makeTranscriber(engine:model:workers:)` routing.
- **Modify** `Sources/MeetingAssistant/Settings.swift` — `transcriptionEngine` persisted setting; thread it into `makeTranscriber`.
- **Modify** `Sources/MeetingAssistant/AppState.swift` — `prepareModel()` builds via the selected engine (already calls `Backends.makeTranscriber`).
- **Modify** `Sources/MeetingAssistant/SettingsView.swift` — engine `Picker` in the Models → Advanced section.
- **Create** `Sources/TranscribeBench/TranscribeBench.swift` + **Modify** `Package.swift` — CLI to benchmark both engines on a wav. (Not named `main.swift` — that conflicts with the `@main` attribute.)

---

### Task 1: `TranscriptionEngine` enum + pure `ParakeetSegmentBuilder`

**Files:**
- Modify: `Sources/MeetingKit/Transcriber.swift` (add the enum near `TranscriptionModel`)
- Create: `Sources/MeetingKit/ParakeetSegmentBuilder.swift`
- Test: `Tests/MeetingKitTests/ParakeetSegmentBuilderTests.swift`

- [ ] **Step 1: Add the `TranscriptionEngine` enum**

In `Sources/MeetingKit/Transcriber.swift`, immediately after the `TranscriptionModel` enum's closing brace (the enum starts at `public enum TranscriptionModel`), add:

```swift
/// Which on-device transcription engine to use. WhisperKit is the default and the
/// multilingual/Mandarin path; Parakeet (NVIDIA, via FluidAudio) is an English-first
/// engine that is much faster on Apple Silicon.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    case whisperKit
    case parakeet

    public var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit (multilingual, best for Mandarin)"
        case .parakeet:   return "Parakeet (English, fastest)"
        }
    }
}
```

- [ ] **Step 2: Write the failing test for the segment builder**

Create `Tests/MeetingKitTests/ParakeetSegmentBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("ParakeetSegmentBuilder")
struct ParakeetSegmentBuilderTests {

    private func tok(_ token: String, _ start: Double, _ end: Double) -> ParakeetToken {
        ParakeetToken(token: token, startTime: start, endTime: end)
    }

    @Test("splits tokens into sentence segments on terminal punctuation") 
    func splitsOnPunctuation() {
        let tokens = [
            tok(" Hello", 0.0, 0.4), tok(" there", 0.4, 0.8), tok(".", 0.8, 0.9),
            tok(" How", 1.0, 1.3), tok(" are", 1.3, 1.5), tok(" you", 1.5, 1.8), tok("?", 1.8, 1.9),
        ]
        let segs = ParakeetSegmentBuilder.segments(
            tokens: tokens, channel: .system, fallbackText: "ignored", fallbackDuration: 2.0
        )
        #expect(segs.count == 2)
        #expect(segs[0].text == "Hello there.")
        #expect(segs[0].start == 0.0)
        #expect(segs[0].end == 0.9)
        #expect(segs[0].channel == .system)
        #expect(segs[1].text == "How are you?")
        #expect(segs[1].start == 1.0)
        #expect(segs[1].end == 1.9)
    }

    @Test("splits on a long pause even without punctuation")
    func splitsOnPause() {
        let tokens = [
            tok(" one", 0.0, 0.4), tok(" two", 0.4, 0.8),
            tok(" three", 3.0, 3.4),   // 2.2s gap > 1.0s threshold
        ]
        let segs = ParakeetSegmentBuilder.segments(
            tokens: tokens, channel: .microphone, fallbackText: "x", fallbackDuration: 4.0
        )
        #expect(segs.count == 2)
        #expect(segs[0].text == "one two")
        #expect(segs[1].text == "three")
        #expect(segs[1].channel == .microphone)
    }

    @Test("with no tokens, emits a single fallback segment spanning the audio")
    func fallbackWhenNoTimings() {
        let segs = ParakeetSegmentBuilder.segments(
            tokens: [], channel: .system, fallbackText: "whole thing", fallbackDuration: 12.5
        )
        #expect(segs.count == 1)
        #expect(segs[0].text == "whole thing")
        #expect(segs[0].start == 0.0)
        #expect(segs[0].end == 12.5)
        #expect(segs[0].channel == .system)
    }

    @Test("trims whitespace and skips empty results")
    func trimsAndSkipsEmpty() {
        let segs = ParakeetSegmentBuilder.segments(
            tokens: [tok("   ", 0.0, 0.1)], channel: .system, fallbackText: "fb", fallbackDuration: 1.0
        )
        // The only token is whitespace → no real segment → fall back to one segment.
        #expect(segs.count == 1)
        #expect(segs[0].text == "fb")
    }
}
```

- [ ] **Step 3: Run it, expect failure**

Run: `swift test --filter ParakeetSegmentBuilderTests`
Expected: FAIL — `cannot find 'ParakeetToken'` / `'ParakeetSegmentBuilder'`.

- [ ] **Step 4: Implement the builder**

Create `Sources/MeetingKit/ParakeetSegmentBuilder.swift`:

```swift
import Foundation

/// A minimal, FluidAudio-free view of one Parakeet token timing, so the
/// segment-building logic stays pure and unit-testable without importing the SDK.
public struct ParakeetToken: Sendable, Equatable {
    public let token: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public init(token: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Turns Parakeet's per-token timings into `[TranscriptSegment]`. Parakeet returns
/// one continuous result with token-level times (not the sentence segments Whisper
/// gives), so we group tokens into segments on sentence-ending punctuation or a
/// long pause — granular enough for `SpeakerFuser` to interleave mic/system and
/// align the on-screen speaker timeline.
public enum ParakeetSegmentBuilder {
    /// Tokens whose trimmed text ends with one of these closes the current segment.
    private static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    /// A silence gap (seconds) between adjacent tokens that also closes a segment.
    private static let pauseThreshold: TimeInterval = 1.0

    public static func segments(
        tokens: [ParakeetToken],
        channel: AudioChannel,
        fallbackText: String,
        fallbackDuration: TimeInterval
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [ParakeetToken] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.token).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: first.startTime, end: last.endTime, text: text, channel: channel
                ))
            }
            current.removeAll()
        }

        for token in tokens {
            if let prev = current.last, token.startTime - prev.endTime >= pauseThreshold {
                flush()
            }
            current.append(token)
            let trimmed = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastChar = trimmed.last, terminators.contains(lastChar) {
                flush()
            }
        }
        flush()

        // No usable tokens (e.g. timings absent) → one segment for the whole clip.
        if segments.isEmpty {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: 0, end: fallbackDuration, text: text, channel: channel
                ))
            }
        }
        return segments
    }
}
```

- [ ] **Step 5: Run it, expect pass**

Run: `swift test --filter ParakeetSegmentBuilderTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingKit/Transcriber.swift Sources/MeetingKit/ParakeetSegmentBuilder.swift Tests/MeetingKitTests/ParakeetSegmentBuilderTests.swift
git commit -m "feat: add TranscriptionEngine enum and pure ParakeetSegmentBuilder"
```

---

### Task 2: `FluidAudioTranscriber` actor

**Files:**
- Modify: `Sources/MeetingKit/Transcriber.swift` (add the actor at the end of the file)

No unit test: this is a FluidAudio framework integration (under `#if canImport(FluidAudio)`); its only pure logic (`ParakeetSegmentBuilder`) is already tested in Task 1. Verified by building and by the Task 6 benchmark.

- [ ] **Step 1: Add the transcriber**

At the END of `Sources/MeetingKit/Transcriber.swift`, append:

```swift
// MARK: - Parakeet engine (compiled only when FluidAudio is available)

#if canImport(FluidAudio)
import FluidAudio
import AVFoundation

/// NVIDIA Parakeet via the FluidAudio SDK. An actor so the model loads exactly once
/// even when the two audio channels are transcribed concurrently (mirrors
/// `WhisperKitTranscriber`). English-first; the app keeps WhisperKit as the
/// multilingual/Mandarin path.
public actor FluidAudioTranscriber: Transcribing {
    private let version: AsrModelVersion
    /// Memoize the load *task* (not the result) so concurrent channels share one
    /// download/load instead of each starting their own.
    private var loadTask: Task<AsrManager, Error>?

    /// `.v2` is the English Parakeet-TDT-0.6B. (`.v3` is multilingual; not used here.)
    public init(version: AsrModelVersion = .v2) {
        self.version = version
    }

    /// Parakeet doesn't expose WhisperKit-style VAD worker tuning; no-op.
    public func setConcurrentWorkers(_ count: Int) {}

    public func prepare(progress: TranscribeProgressHandler?) async throws {
        _ = try await manager(progress: progress)
    }

    private func manager(progress: TranscribeProgressHandler?) async throws -> AsrManager {
        if let loadTask { return try await loadTask.value }
        let version = self.version
        let task = Task { () throws -> AsrManager in
            progress?(TranscribeProgress(fraction: nil, phase: "Preparing Parakeet model…"))
            let models = try await AsrModels.downloadAndLoad(version: version)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            return mgr
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil   // let a later call retry a failed download/load
            throw error
        }
    }

    public func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        let mgr = try await manager(progress: progress)
        let label = channel == .microphone ? "Transcribing your audio…" : "Transcribing others' audio…"
        progress?(TranscribeProgress(fraction: 0, phase: label))

        var state = try TdtDecoderState()
        let result = try await mgr.transcribe(audioFile, decoderState: &state)
        progress?(TranscribeProgress(fraction: 1, phase: label))

        let tokens = (result.tokenTimings ?? []).map {
            ParakeetToken(token: $0.token, startTime: $0.startTime, endTime: $0.endTime)
        }
        let segments = ParakeetSegmentBuilder.segments(
            tokens: tokens,
            channel: channel,
            fallbackText: result.text,
            fallbackDuration: result.duration
        )
        // Reuse the same silence/stock-phrase cleanup the WhisperKit path applies.
        return HallucinationFilter.clean(segments)
    }
}
#endif
```

- [ ] **Step 2: Build (full Xcode compiles the FluidAudio path)**

Run: `swift build`
Expected: Build complete, no errors. (If the compiler flags the `inout` decoderState across the actor call or a name mismatch, re-read `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift` and adjust the call to the resolved signature — do NOT guess.)

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingKit/Transcriber.swift
git commit -m "feat: add FluidAudioTranscriber (Parakeet) backend"
```

---

### Task 3: Route engine selection through `Backends` + `AppSettings`

**Files:**
- Modify: `Sources/MeetingKit/Backends.swift`
- Modify: `Sources/MeetingAssistant/Settings.swift`

- [ ] **Step 1: Add engine-aware factory in `Backends`**

In `Sources/MeetingKit/Backends.swift`, replace `makeTranscriber(model:workers:)` (lines 11-17) with:

```swift
    public static func makeTranscriber(
        engine: TranscriptionEngine = .whisperKit,
        model: TranscriptionModel,
        workers: Int = 4
    ) -> Transcribing {
        switch engine {
        case .parakeet:
            #if canImport(FluidAudio)
            return FluidAudioTranscriber()
            #else
            return StubTranscriber()
            #endif
        case .whisperKit:
            #if canImport(WhisperKit)
            return WhisperKitTranscriber(model: model, concurrentWorkers: workers)
            #else
            return StubTranscriber()
            #endif
        }
    }
```

- [ ] **Step 2: Add the persisted `transcriptionEngine` setting**

In `Sources/MeetingAssistant/Settings.swift`:

(a) After the `transcriptionModel` published property (lines 10-12), add:

```swift
    /// Which transcription engine to use. WhisperKit by default (multilingual);
    /// Parakeet is an English-first, much faster Apple-Silicon engine.
    @Published var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }
```

(b) In `enum Keys`, add:

```swift
        static let transcriptionEngine = "transcriptionEngine"
```

(c) In `init`, after `transcriptionModel` is set (line 53), add:

```swift
        self.transcriptionEngine = TranscriptionEngine(
            rawValue: defaults.string(forKey: Keys.transcriptionEngine) ?? ""
        ) ?? .whisperKit
```

(d) Replace `makeTranscriber()` (lines 66-69) with:

```swift
    /// Build the on-device transcriber for the selected engine.
    func makeTranscriber() -> Transcribing {
        Backends.makeTranscriber(
            engine: transcriptionEngine,
            model: transcriptionModel,
            workers: transcriptionWorkers
        )
    }
```

- [ ] **Step 3: Point `AppState.prepareModel` at the selected engine**

In `Sources/MeetingAssistant/AppState.swift`, `prepareModel()` currently builds the transcriber inline via `Backends.makeTranscriber(model:workers:)`. Replace that call (it appears once, around line 188) so it uses the settings-aware factory:

```swift
        transcriber = settings.makeTranscriber()
```

(There is also an identical `Backends.makeTranscriber(...)` in `init` around line 122 — replace it with `settings.makeTranscriber()` too so launch and re-prepare agree. `settings` is already assigned before that line.)

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: all pass (no behavior change to the default WhisperKit path).

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/Backends.swift Sources/MeetingAssistant/Settings.swift Sources/MeetingAssistant/AppState.swift
git commit -m "feat: select transcription engine via settings, routed through Backends"
```

---

### Task 4: Settings UI engine picker

**Files:**
- Modify: `Sources/MeetingAssistant/SettingsView.swift`

- [ ] **Step 1: Add the engine picker**

In `Sources/MeetingAssistant/SettingsView.swift`, inside the `DisclosureGroup("Advanced")` of `modelsTab` (after the "Quality" picker block, ~line 166, before the closing `}` of the DisclosureGroup), add:

```swift
                Picker("Engine", selection: Binding(
                    get: { state.settings.transcriptionEngine },
                    set: { state.settings.transcriptionEngine = $0 }
                )) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: state.settings.transcriptionEngine) {
                    // Switching engines loads a different model.
                    Task { await state.prepareModel() }
                }
                Text("Parakeet is much faster on Apple Silicon and English-only. "
                     + "WhisperKit stays best for Mandarin and other languages.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/SettingsView.swift
git commit -m "feat: add transcription engine picker to Settings"
```

---

### Task 5: `TranscribeBench` CLI to compare engines

**Files:**
- Modify: `Package.swift` (add an executable target)
- Create: `Sources/TranscribeBench/TranscribeBench.swift`

- [ ] **Step 1: Add the executable target to `Package.swift`**

In `Package.swift`, add to `products` (alongside the existing ones) an executable product, and to `targets` an executable target that depends on `MeetingKit`:

```swift
        .executable(name: "TranscribeBench", targets: ["TranscribeBench"]),
```

```swift
        .executableTarget(
            name: "TranscribeBench",
            dependencies: ["MeetingKit"],
            path: "Sources/TranscribeBench"
        ),
```

(Read the current `Package.swift` first and insert these into the existing `products:` and `targets:` arrays without disturbing the app/library targets.)

- [ ] **Step 2: Write the benchmark**

Create `Sources/TranscribeBench/TranscribeBench.swift`:

```swift
import Foundation
import AVFoundation
import MeetingKit

// Compare WhisperKit vs Parakeet on one audio file: wall-clock, RTFx, and text.
// Usage: swift run TranscribeBench /path/to/audio.wav

@main
struct TranscribeBench {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: TranscribeBench <audio-file> [whisperKit|parakeet|both]\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1])
        let which = args.count >= 3 ? args[2] : "both"

        let duration = audioDuration(url)
        print("File: \(url.lastPathComponent)  duration: \(String(format: "%.1f", duration))s\n")

        if which == "whisperKit" || which == "both" {
            await run(label: "WhisperKit", engine: .whisperKit, url: url, duration: duration)
        }
        if which == "parakeet" || which == "both" {
            await run(label: "Parakeet", engine: .parakeet, url: url, duration: duration)
        }
    }

    static func run(label: String, engine: TranscriptionEngine, url: URL, duration: Double) async {
        let t = Backends.makeTranscriber(engine: engine, model: .largeTurbo, workers: 4)
        do {
            try await t.prepare(progress: nil)
            let start = Date()
            let segments = try await t.transcribe(audioFile: url, channel: .system, progress: nil)
            let elapsed = Date().timeIntervalSince(start)
            let rtfx = duration > 0 ? duration / elapsed : 0
            let text = segments.map(\.text).joined(separator: " ")
            print("== \(label) ==")
            print(String(format: "  wall: %.2fs   RTFx: %.1fx   segments: %d", elapsed, rtfx, segments.count))
            print("  text: \(text.prefix(280))\n")
        } catch {
            print("== \(label) ==\n  ERROR: \(error)\n")
        }
    }

    static func audioDuration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build complete (the new target compiles).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/TranscribeBench/main.swift
git commit -m "feat: add TranscribeBench CLI to compare WhisperKit vs Parakeet"
```

---

### Task 6: Run the head-to-head benchmark (manual)

**Files:** none — this is the spike's payoff: real numbers on a real Mac.

- [ ] **Step 1: Find a real recording's audio**

Captured meetings live under `~/Library/Application Support/MeetingAssistant/…`; each bundle has `mic.wav` / `system.wav`. Pick one with real English speech (and, if available, a Mandarin one).

Run: `ls -1 ~/Library/Application\ Support/MeetingAssistant`  (then locate a meeting folder's `system.wav`).

- [ ] **Step 2: Benchmark both engines**

Run: `swift run TranscribeBench "/absolute/path/to/system.wav" both`
Expected: prints wall-clock, RTFx, segment count, and a text preview for each engine. (First run downloads the Parakeet model — allow time + disk.)

- [ ] **Step 3: Record the result in the decision record**

Append the measured numbers (RTFx for each engine, plus a subjective accuracy note on the English clip and, if tested, the Mandarin clip) to `docs/decisions/2026-06-17-transcription-engine.md` under a new "## Spike results" heading. Commit:

```bash
git add docs/decisions/2026-06-17-transcription-engine.md
git commit -m "docs: record Parakeet vs WhisperKit benchmark results"
```

- [ ] **Step 4: Verify the app picker end-to-end**

Run: `./Scripts/build-app.sh --run`
In Settings → Models → Advanced, switch Engine to **Parakeet**; confirm it downloads/prepares and that transcribing a recording produces a speaker-labeled transcript with sensible timestamps (mic/system split preserved). Switch back to WhisperKit and confirm it still works.

---

## Notes

- **Default unchanged:** WhisperKit remains the default engine; Parakeet is opt-in via Settings. No regression to the multilingual/Mandarin path (N5, R5).
- **Attribution:** if Parakeet ships as a real option later, add CC-BY-4.0 attribution (NVIDIA + FluidInference) to the app's about/licenses. Out of scope for the spike.
- **Known caveats** (from the decision record): benchmark numbers are hardware-dependent; meeting audio is harder than benchmark audio; Mandarin accuracy for Parakeet is unmeasured — hence keeping WhisperKit as fallback.
- **If the build flags the FluidAudio API:** the resolved version is 0.15.3; the authoritative signatures are in `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/…`. Re-read and match them rather than guessing.
