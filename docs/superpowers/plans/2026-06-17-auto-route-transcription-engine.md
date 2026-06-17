# Auto-route transcription engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `auto` transcription engine that detects each channel's language and routes English/European audio to fast Parakeet (v3, language-hinted) and Mandarin/other/uncertain to WhisperKit — capturing the speed win with no Mandarin regression.

**Architecture:** A pure `EngineRouter` decides engine from a detected language + confidence. A `LanguageDetecting` capability (implemented by WhisperKit) supplies the detection. `AutoRoutingTranscriber` composes the detector + both engines and delegates per channel. A new `Transcribing.transcribe(…languageHint:…)` variant lets the router pass the detected language to Parakeet v3.

**Tech Stack:** Swift 6, WhisperKit (`detectLanguage`), FluidAudio 0.15.3 (`Language`), swift-testing.

---

## Verified APIs

- `WhisperKit.detectLanguage(audioPath: String) async throws -> (language: String, langProbs: [String: Float])` — uses only the first 30 s. `language` is an ISO code ("en", "zh", "es", …); confidence = `langProbs[language]`.
- `FluidAudio.Language: String` (cases "en","es",…,"el"; **no CJK**) → `Language(rawValue: code)` is non-nil iff Parakeet supports that code.
- `AsrManager.transcribe(_ url:URL, decoderState: inout TdtDecoderState, language: Language? = nil)` — the `language` hint is honored by `.v3` (script-aware token filtering), ignored by `.v2`.
- Current `Transcribing` protocol: `prepare`, `setConcurrentWorkers`, `transcribe(audioFile:channel:progress:)`.

---

## File Structure

- **Create** `Sources/MeetingKit/EngineRouter.swift` — pure routing decision + `DetectedLanguage` + `LanguageDetecting` protocol.
- **Create** `Tests/MeetingKitTests/EngineRouterTests.swift` — router unit tests.
- **Modify** `Sources/MeetingKit/Transcriber.swift` — add `transcribe(…languageHint:…)` to the protocol (+ default); `FluidAudioTranscriber` honors the hint; `WhisperKitTranscriber` conforms to `LanguageDetecting`.
- **Create** `Sources/MeetingKit/AutoRoutingTranscriber.swift` — the composed engine.
- **Create** `Tests/MeetingKitTests/AutoRoutingTranscriberTests.swift` — orchestration tests with stubs.
- **Modify** `Sources/MeetingKit/Backends.swift` — build `AutoRoutingTranscriber` for `.auto`.
- **Modify** `Sources/MeetingKit/Transcriber.swift` (enum) — add `TranscriptionEngine.auto`.
- **Modify** `Sources/MeetingAssistant/Settings.swift` — default to `.auto`.
- **Modify** `Sources/MeetingAssistant/SettingsView.swift` — picker shows Automatic.
- **Modify** `Sources/TranscribeBench/TranscribeBench.swift` — add `auto` to the CLI.

---

### Task 1: Pure `EngineRouter` + `LanguageDetecting`

**Files:**
- Create: `Sources/MeetingKit/EngineRouter.swift`
- Test: `Tests/MeetingKitTests/EngineRouterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/EngineRouterTests.swift`:

```swift
import Testing
@testable import MeetingKit

@Suite("EngineRouter")
struct EngineRouterTests {

    @Test("confident English routes to Parakeet")
    func englishToParakeet() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "en", confidence: 0.95))
        #expect(r == .parakeet(languageCode: "en"))
    }

    @Test("confident Spanish (a Parakeet language) routes to Parakeet")
    func spanishToParakeet() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "es", confidence: 0.8))
        #expect(r == .parakeet(languageCode: "es"))
    }

    @Test("Mandarin routes to WhisperKit (Parakeet has no CJK)")
    func mandarinToWhisper() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "zh", confidence: 0.99))
        #expect(r == .whisperKit)
    }

    @Test("low confidence routes to WhisperKit even for English")
    func lowConfidenceToWhisper() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "en", confidence: 0.3))
        #expect(r == .whisperKit)
    }

    @Test("unknown/unsupported code routes to WhisperKit")
    func unknownToWhisper() {
        let r = EngineRouter.route(detected: DetectedLanguage(code: "ja", confidence: 0.9))
        #expect(r == .whisperKit)
    }

    @Test("nil detection routes to WhisperKit")
    func nilToWhisper() {
        let r = EngineRouter.route(detected: nil)
        #expect(r == .whisperKit)
    }
}
```

- [ ] **Step 2: Run it, expect failure**

Run: `swift test --filter EngineRouterTests`
Expected: FAIL — `cannot find 'EngineRouter' / 'DetectedLanguage'`.

- [ ] **Step 3: Implement**

Create `Sources/MeetingKit/EngineRouter.swift`:

```swift
import Foundation

/// The language detected for a piece of audio, with the detector's confidence.
public struct DetectedLanguage: Sendable, Equatable {
    public let code: String        // ISO-ish code, e.g. "en", "zh", "es"
    public let confidence: Double  // 0...1
    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }
}

/// Detects the spoken language of an audio file (a cheap pass, not a full
/// transcription). Implemented by the WhisperKit backend, which loads the
/// multilingual model anyway.
public protocol LanguageDetecting: Sendable {
    /// Returns the detected language, or nil when it can't decide.
    func detectLanguage(audioFile: URL) async throws -> DetectedLanguage?
}

/// Which engine a channel should use, decided from its detected language.
public enum RoutedEngine: Sendable, Equatable {
    case whisperKit
    case parakeet(languageCode: String)
}

/// Pure routing policy for the `auto` engine: send confidently-detected
/// English/European audio to fast Parakeet (which can take a language hint), and
/// everything else — CJK, unknown scripts, or low-confidence — to WhisperKit.
public enum EngineRouter {
    /// Languages Parakeet `.v3` supports (mirrors FluidAudio's `Language` enum).
    /// Deliberately has NO CJK — Parakeet produces gibberish on Mandarin.
    public static let parakeetLanguages: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "ro", "nl", "da", "sv", "fi", "hu",
        "et", "lv", "lt", "mt", "pl", "cs", "sk", "sl", "hr", "bs", "ru", "uk",
        "be", "bg", "sr", "el",
    ]

    public static func route(
        detected: DetectedLanguage?,
        threshold: Double = 0.5
    ) -> RoutedEngine {
        guard let d = detected,
              d.confidence >= threshold,
              parakeetLanguages.contains(d.code) else {
            return .whisperKit
        }
        return .parakeet(languageCode: d.code)
    }
}
```

- [ ] **Step 4: Run it, expect pass**

Run: `swift test --filter EngineRouterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Full suite + commit**

Run: `swift test`  → all pass.

```bash
git add Sources/MeetingKit/EngineRouter.swift Tests/MeetingKitTests/EngineRouterTests.swift
git commit -m "feat: add pure EngineRouter and LanguageDetecting for auto routing"
```

---

### Task 2: `languageHint` transcribe variant + Parakeet honors it

**Files:**
- Modify: `Sources/MeetingKit/Transcriber.swift`

No new unit test: the hint plumbing is exercised by Task 4's orchestration test and the FluidAudio path is a framework integration (verified by build + benchmark).

- [ ] **Step 1: Add the protocol method + default**

In `Sources/MeetingKit/Transcriber.swift`, in the `public protocol Transcribing` body, after the existing `transcribe(audioFile:channel:progress:)` requirement, add:

```swift
    /// Transcribe with an optional detected-language hint. Engines that auto-detect
    /// (WhisperKit) ignore it; Parakeet `.v3` uses it for script-aware filtering.
    func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        languageHint: String?,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment]
```

In the `public extension Transcribing` block (where the convenience overload lives), add a default that ignores the hint:

```swift
    /// Default: ignore the hint and transcribe normally (right for auto-detecting
    /// engines like WhisperKit and for the stub).
    func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        languageHint: String?,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        try await transcribe(audioFile: audioFile, channel: channel, progress: progress)
    }
```

- [ ] **Step 2: Make `FluidAudioTranscriber` honor the hint**

In `FluidAudioTranscriber` (the `#if canImport(FluidAudio)` actor), add an override that maps the code to `FluidAudio.Language` and passes it to the manager. Insert this method right after the existing `transcribe(audioFile:channel:progress:)`:

```swift
    public func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        languageHint: String?,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        let mgr = try await manager(progress: progress)
        let label = channel == .microphone ? "Transcribing your audio…" : "Transcribing others' audio…"
        progress?(TranscribeProgress(fraction: 0, phase: label))

        var state = try TdtDecoderState()
        let lang = languageHint.flatMap(Language.init(rawValue:))
        let result = try await mgr.transcribe(audioFile, decoderState: &state, language: lang)
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
        return HallucinationFilter.clean(segments)
    }
```

(The existing no-hint `transcribe(audioFile:channel:progress:)` stays as-is — it's used by the standalone `.parakeet` engine on `.v2`.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingKit/Transcriber.swift
git commit -m "feat: add language-hint transcribe variant; Parakeet honors it"
```

---

### Task 3: `WhisperKitTranscriber` conforms to `LanguageDetecting`

**Files:**
- Modify: `Sources/MeetingKit/Transcriber.swift`

No unit test: WhisperKit framework integration (verified by build + benchmark).

- [ ] **Step 1: Add conformance + detect method**

In `Sources/MeetingKit/Transcriber.swift`, change the `WhisperKitTranscriber` declaration to also conform to `LanguageDetecting`:

```swift
public actor WhisperKitTranscriber: Transcribing, LanguageDetecting {
```

Then add this method inside the actor (e.g. right after `transcribe(audioFile:channel:progress:)`):

```swift
    /// Cheap language detection (WhisperKit uses only the first 30 s). Returns the
    /// top language and its probability; nil if detection throws.
    public func detectLanguage(audioFile: URL) async throws -> DetectedLanguage? {
        let pipe = try await pipeline(progress: nil)
        guard let result = try? await pipe.detectLanguage(audioPath: audioFile.path) else {
            return nil
        }
        let confidence = Double(result.langProbs[result.language] ?? 0)
        return DetectedLanguage(code: result.language, confidence: confidence)
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingKit/Transcriber.swift
git commit -m "feat: WhisperKitTranscriber conforms to LanguageDetecting"
```

---

### Task 4: `AutoRoutingTranscriber` + orchestration tests

**Files:**
- Create: `Sources/MeetingKit/AutoRoutingTranscriber.swift`
- Test: `Tests/MeetingKitTests/AutoRoutingTranscriberTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/AutoRoutingTranscriberTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("AutoRoutingTranscriber")
struct AutoRoutingTranscriberTests {

    // Detector that returns a preset language.
    private struct StubDetector: LanguageDetecting {
        let result: DetectedLanguage?
        func detectLanguage(audioFile: URL) async throws -> DetectedLanguage? { result }
    }

    // Engine that records whether it was called and tags its name into the segment.
    private actor SpyEngine: Transcribing {
        let name: String
        private(set) var lastHint: String??
        init(name: String) { self.name = name }
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func setConcurrentWorkers(_ count: Int) async {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?) async throws -> [TranscriptSegment] {
            [TranscriptSegment(start: 0, end: 1, text: name, channel: channel)]
        }
        func transcribe(audioFile: URL, channel: AudioChannel, languageHint: String?, progress: TranscribeProgressHandler?) async throws -> [TranscriptSegment] {
            lastHint = languageHint
            return [TranscriptSegment(start: 0, end: 1, text: name, channel: channel)]
        }
        func recordedHint() -> String?? { lastHint }
    }

    private func url() -> URL { URL(fileURLWithPath: "/tmp/x.wav") }

    @Test("English routes to Parakeet with the language hint")
    func englishToParakeet() async throws {
        let whisper = SpyEngine(name: "whisper")
        let parakeet = SpyEngine(name: "parakeet")
        let auto = AutoRoutingTranscriber(
            detector: StubDetector(result: DetectedLanguage(code: "en", confidence: 0.9)),
            whisper: whisper, parakeet: parakeet
        )
        let segs = try await auto.transcribe(audioFile: url(), channel: .system, progress: nil)
        #expect(segs.first?.text == "parakeet")
        #expect(await parakeet.recordedHint() == .some("en"))
    }

    @Test("Mandarin routes to WhisperKit")
    func mandarinToWhisper() async throws {
        let whisper = SpyEngine(name: "whisper")
        let parakeet = SpyEngine(name: "parakeet")
        let auto = AutoRoutingTranscriber(
            detector: StubDetector(result: DetectedLanguage(code: "zh", confidence: 0.99)),
            whisper: whisper, parakeet: parakeet
        )
        let segs = try await auto.transcribe(audioFile: url(), channel: .microphone, progress: nil)
        #expect(segs.first?.text == "whisper")
    }

    @Test("detector returning nil routes to WhisperKit")
    func nilDetectionToWhisper() async throws {
        let whisper = SpyEngine(name: "whisper")
        let parakeet = SpyEngine(name: "parakeet")
        let auto = AutoRoutingTranscriber(
            detector: StubDetector(result: nil),
            whisper: whisper, parakeet: parakeet
        )
        let segs = try await auto.transcribe(audioFile: url(), channel: .system, progress: nil)
        #expect(segs.first?.text == "whisper")
    }
}
```

- [ ] **Step 2: Run it, expect failure**

Run: `swift test --filter AutoRoutingTranscriberTests`
Expected: FAIL — `cannot find 'AutoRoutingTranscriber'`.

- [ ] **Step 3: Implement**

Create `Sources/MeetingKit/AutoRoutingTranscriber.swift`:

```swift
import Foundation

/// The `auto` engine: detects each channel's language and routes it to the right
/// backend — fast Parakeet for English/European, WhisperKit for Mandarin/other or
/// when detection is uncertain. Routing is per channel, so a bilingual meeting
/// (English mic, Mandarin system) is handled correctly. Output is identical in
/// shape to either engine (channel-tagged, timestamped segments), so SpeakerFuser
/// and the mic/system split are unaffected.
public actor AutoRoutingTranscriber: Transcribing {
    private let detector: LanguageDetecting
    private let whisper: Transcribing
    private let parakeet: Transcribing
    /// Prepare Parakeet lazily — an all-Mandarin user never pays its download/load.
    private var parakeetPrepared = false

    public init(detector: LanguageDetecting, whisper: Transcribing, parakeet: Transcribing) {
        self.detector = detector
        self.whisper = whisper
        self.parakeet = parakeet
    }

    public func prepare(progress: TranscribeProgressHandler?) async throws {
        // The detector (WhisperKit) is always needed — for detection and for any
        // non-Parakeet channel. Parakeet is prepared on first use.
        try await whisper.prepare(progress: progress)
    }

    public func setConcurrentWorkers(_ count: Int) async {
        await whisper.setConcurrentWorkers(count)
    }

    public func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        let detected = try? await detector.detectLanguage(audioFile: audioFile)
        switch EngineRouter.route(detected: detected) {
        case .whisperKit:
            return try await whisper.transcribe(audioFile: audioFile, channel: channel, progress: progress)
        case .parakeet(let code):
            if !parakeetPrepared {
                try await parakeet.prepare(progress: progress)
                parakeetPrepared = true
            }
            return try await parakeet.transcribe(
                audioFile: audioFile, channel: channel, languageHint: code, progress: progress
            )
        }
    }
}
```

- [ ] **Step 4: Run it, expect pass**

Run: `swift test --filter AutoRoutingTranscriberTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Full suite + commit**

Run: `swift test` → all pass.

```bash
git add Sources/MeetingKit/AutoRoutingTranscriber.swift Tests/MeetingKitTests/AutoRoutingTranscriberTests.swift
git commit -m "feat: add AutoRoutingTranscriber (per-channel language routing)"
```

---

### Task 5: `.auto` engine, Backends wiring, default + Settings

**Files:**
- Modify: `Sources/MeetingKit/Transcriber.swift` (enum)
- Modify: `Sources/MeetingKit/Backends.swift`
- Modify: `Sources/MeetingAssistant/Settings.swift`
- Modify: `Sources/MeetingAssistant/SettingsView.swift`

- [ ] **Step 1: Add the `.auto` case**

In `Sources/MeetingKit/Transcriber.swift`, in `TranscriptionEngine`, add `auto` as the first case and a display name:

```swift
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    case auto
    case whisperKit
    case parakeet

    public var displayName: String {
        switch self {
        case .auto:       return "Automatic (fast English, accurate Mandarin)"
        case .whisperKit: return "WhisperKit (multilingual, best for Mandarin)"
        case .parakeet:   return "Parakeet (English, fastest)"
        }
    }
}
```

- [ ] **Step 2: Build the auto engine in `Backends`**

In `Sources/MeetingKit/Backends.swift`, add an `.auto` case to the `switch engine` in `makeTranscriber`, before `.whisperKit`:

```swift
        case .auto:
            #if canImport(WhisperKit) && canImport(FluidAudio)
            let whisper = WhisperKitTranscriber(model: model, concurrentWorkers: workers)
            return AutoRoutingTranscriber(
                detector: whisper,
                whisper: whisper,
                parakeet: FluidAudioTranscriber(version: .v3)
            )
            #elseif canImport(WhisperKit)
            return WhisperKitTranscriber(model: model, concurrentWorkers: workers)
            #else
            return StubTranscriber()
            #endif
```

- [ ] **Step 3: Default to `.auto`**

In `Sources/MeetingAssistant/Settings.swift`, change the engine default fallback from `.whisperKit` to `.auto`:

```swift
        // Automatic by default: routes each channel to the fastest engine that
        // handles its language (Parakeet for English/European, WhisperKit for
        // Mandarin/other). See docs/decisions/2026-06-17-transcription-engine.md.
        self.transcriptionEngine = TranscriptionEngine(
            rawValue: defaults.string(forKey: Keys.transcriptionEngine) ?? ""
        ) ?? .auto
```

- [ ] **Step 4: Picker copy**

In `Sources/MeetingAssistant/SettingsView.swift`, the engine `Picker` already iterates `TranscriptionEngine.allCases`, so `.auto` appears automatically. Replace the helper `Text` under the engine picker so it describes auto:

```swift
                Text("Automatic uses fast Parakeet for English/European speech and "
                     + "WhisperKit for Mandarin and other languages. Pick a specific "
                     + "engine to override.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 5: Build + test**

Run: `swift build` → Build complete.
Run: `swift test` → all pass (router + auto + existing 109).

- [ ] **Step 6: Commit**

```bash
git add Sources/MeetingKit/Transcriber.swift Sources/MeetingKit/Backends.swift Sources/MeetingAssistant/Settings.swift Sources/MeetingAssistant/SettingsView.swift
git commit -m "feat: add auto engine, route per language, make it the default"
```

---

### Task 6: Extend `TranscribeBench` + manual verification

**Files:**
- Modify: `Sources/TranscribeBench/TranscribeBench.swift`

- [ ] **Step 1: Add `auto` to the CLI**

In `Sources/TranscribeBench/TranscribeBench.swift`, in `main`, after the existing `parakeet` block, add:

```swift
        if which == "auto" || which == "both" {
            await run(label: "Auto", engine: .auto, url: url, duration: duration)
        }
```

- [ ] **Step 2: Build**

Run: `swift build` → Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/TranscribeBench/TranscribeBench.swift
git commit -m "feat: add auto mode to TranscribeBench"
```

- [ ] **Step 4: Manual verification (user)**

Run on a known **English** recording and the known **Mandarin** recording:

```
swift run TranscribeBench "<english>/mic.wav" auto
swift run TranscribeBench "<…99D0EA4E>/mic.wav" auto
```

Expected:
- English clip → auto produces a fast, accurate English transcript (routed to Parakeet; RTFx ≫ 10×).
- Mandarin clip → auto produces an accurate Mandarin transcript (routed to WhisperKit; correct 中文, not gibberish).

- [ ] **Step 5: Verify in the app**

Run: `./Scripts/build-app.sh --run`. In Settings → Models → Advanced, confirm **Automatic** is selected by default; transcribe an English and a Mandarin recording and confirm each is handled correctly with intact speaker labels/timestamps.

---

## Notes

- **No regression:** anything Parakeet can't do (Mandarin, low-confidence, detector error) falls back to WhisperKit. Auto is strictly safer than a Parakeet default.
- **Cost:** auto keeps the WhisperKit model resident (detection + non-European channels); Parakeet `.v3` loads lazily on first English/European channel. Worst case (bilingual meeting) both are resident — heavier on 16 GB Macs.
- **Threshold:** `EngineRouter.route` default `threshold: 0.5`; if real recordings show borderline Mandarin slipping to Parakeet, raise it (err high). Tunable in one place.
- **Docs:** after this lands, update `REQUIREMENTS.md` R5 and `CLAUDE.md` to note `auto` is the default (do it in Task 5's commit or a follow-up `docs:` commit).
- **`auto` accuracy on non-English European languages** relies on Parakeet `.v3` + the language hint; unverified per-language — revisit if one reads poorly.
