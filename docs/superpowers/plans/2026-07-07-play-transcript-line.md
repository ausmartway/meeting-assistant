# Play a Transcript Line's Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hovering a transcript line reveals a play button that plays that line's audio (precise via a new `segments.json`; best-effort timestamp fallback for old recordings), so the user can verify named speakers by ear.

**Architecture:** `LabeledSegment` gains an optional `channel`; `MeetingProcessor` persists the fused segments as `segments.json` next to `transcript.md`. A pure `TranscriptAudioLocator` maps each parsed transcript turn to a `ClipLocation {fileName, start, end}` — index-paired to segments when they exist and sanity-check, else derived from the turn's wall-clock stamp. An app-target `ClipPlayer` (AVAudioPlayer) plays one clip at a time; `TranscriptReadingView` shows a hover play/stop button per turn.

**Tech Stack:** Swift 5 / SwiftPM, swift-testing (`@Suite`/`@Test`/`#expect`), AVFoundation (app target only), macOS 26 target. Spec: `docs/superpowers/specs/2026-07-07-play-transcript-line-design.md`.

## Global Constraints

- Pure logic lives in `Sources/MeetingKit/` with tests written FIRST (TDD); app-target code (`Sources/MeetingAssistant/`) has no unit tests by project convention — the gate there is `swift build` + full suite green.
- Fallback window rules (exact values): end = next turn's offset, capped at start + 30 s; last turn end = start + 15 s; midnight wrap adds 24 h when the wall-clock difference is negative.
- Channel fallback: turn speaker == local user name (exact string match) → mic file, else system file.
- Do NOT use heredocs/echo/cat to write files (a hook blocks them); use Write/Edit tools. Write each commit message to a file under `.superpowers/sdd/` and `git commit -F <path>`.
- Every commit message ends with the two trailers:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_017HLv3fU6wSSkNYsMx5qbTq`
- Run `swift test --filter <SuiteName>` per task and full `swift test` before each commit.

---

### Task 1: `LabeledSegment.channel` + `SpeakerFuser` threads it

**Files:**
- Modify: `Sources/MeetingKit/Models.swift` (LabeledSegment, ~line 162)
- Modify: `Sources/MeetingKit/SpeakerFuser.swift` (the `LabeledSegment(...)` return in `fuse`, ~line 65)
- Test: `Tests/MeetingKitTests/LabeledSegmentChannelTests.swift` (create)

**Interfaces:**
- Consumes: existing `AudioChannel` enum (`.microphone`/`.system`), `TranscriptSegment.channel`.
- Produces: `LabeledSegment.channel: AudioChannel?` (nil-defaulting init parameter placed LAST so existing call sites compile unchanged); JSON without a `channel` key decodes to nil; `SpeakerFuser.fuse` output carries each source segment's channel.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("LabeledSegment.channel")
struct LabeledSegmentChannelTests {

    @Test("channel round-trips through JSON")
    func roundTrip() throws {
        let seg = LabeledSegment(
            start: 1, end: 2, text: "hi", speaker: "Sam", channel: .system)
        let decoded = try JSONDecoder().decode(
            LabeledSegment.self, from: JSONEncoder().encode(seg))
        #expect(decoded.channel == .system)
    }

    @Test("JSON without a channel key decodes to nil (legacy)")
    func legacyDecode() throws {
        let legacy = """
            {"start": 1, "end": 2, "text": "hi", "speaker": "Sam"}
            """
        let decoded = try JSONDecoder().decode(
            LabeledSegment.self, from: Data(legacy.utf8))
        #expect(decoded.channel == nil)
    }

    @Test("fuse carries each source segment's channel")
    func fuseCarriesChannel() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "a", channel: .microphone),
            TranscriptSegment(start: 1, end: 2, text: "b", channel: .system),
        ]
        let labeled = SpeakerFuser.fuse(
            segments: segments, timeline: SpeakerTimeline(samples: []))
        #expect(labeled.map(\.channel) == [.microphone, .system])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter LabeledSegmentChannelTests` → compile FAIL (`channel` not a member).

- [ ] **Step 3: Implement**

Replace `LabeledSegment` in `Sources/MeetingKit/Models.swift`:

```swift
/// A transcript segment after speaker fusion: it now carries a resolved label.
public struct LabeledSegment: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let speaker: String  // "Me", an OCR'd name, or "Speaker N"
    /// Which audio file this segment came from — lets the UI play the exact
    /// clip back (`segments.json`). Nil for segments saved before this existed.
    public let channel: AudioChannel?

    public init(
        start: TimeInterval, end: TimeInterval, text: String, speaker: String,
        channel: AudioChannel? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.channel = channel
    }
}
```

(Synthesized Codable decodes a missing `channel` key as an error for non-optional types, but `channel` is Optional — Swift's synthesized decoder uses `decodeIfPresent` for optionals, so the legacy test passes with NO custom Codable. Verify with the test rather than adding boilerplate.)

In `Sources/MeetingKit/SpeakerFuser.swift`, the return inside `fuse` becomes:

```swift
            return LabeledSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speaker,
                channel: segment.channel
            )
```

- [ ] **Step 4: Run tests** — `swift test --filter LabeledSegmentChannelTests` → PASS; full `swift test` → PASS.

- [ ] **Step 5: Commit** — `feat: LabeledSegment carries its source audio channel`

---

### Task 2: `MeetingStore` segments persistence + `MeetingProcessor` writes it

**Files:**
- Modify: `Sources/MeetingKit/MeetingStore.swift` (add next to `saveSpeakerMap`/`speakerMap`, ~line 55)
- Modify: `Sources/MeetingKit/MeetingProcessor.swift` (after `try store.saveTranscript(...)`, ~line 168)
- Test: `Tests/MeetingKitTests/MeetingStoreSegmentsTests.swift` (create)

**Interfaces:**
- Consumes: `LabeledSegment` with `channel` (Task 1); existing `directory(for:)`, `bundleURL(for:)` patterns in MeetingStore.
- Produces: `MeetingStore.saveSegments(_ segments: [LabeledSegment], for meetingID: String) throws` and `MeetingStore.segments(for meetingID: String) -> [LabeledSegment]?` (nil when absent/unreadable). `MeetingProcessor` writes `segments.json` right after the transcript.

- [ ] **Step 1: Write the failing test** (follow the construction pattern used by the existing `Tests/MeetingKitTests/MeetingStoreTests.swift` — read it first and build the store against a temp directory the same way):

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingStore segments")
struct MeetingStoreSegmentsTests {

    @Test("segments round-trip through segments.json")
    func roundTrip() throws {
        // Construct MeetingStore against a fresh temp root exactly the way
        // MeetingStoreTests does (same init + cleanup pattern).
        let store = try makeTempStore()
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "hi", speaker: "Me", channel: .microphone),
            LabeledSegment(start: 2, end: 5, text: "yo", speaker: "Sam", channel: .system),
        ]
        try store.saveSegments(segments, for: "m1")
        #expect(store.segments(for: "m1") == segments)
    }

    @Test("missing segments.json returns nil")
    func missing() throws {
        let store = try makeTempStore()
        #expect(store.segments(for: "nope") == nil)
    }
}
```

(`makeTempStore()` is a small private helper in this file mirroring MeetingStoreTests' store construction.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter "MeetingStore segments"` → compile FAIL.

- [ ] **Step 3: Implement**

In `MeetingStore`, next to the speaker-map methods:

```swift
    /// Persist the fused, labeled segments (`segments.json`) so the UI can play
    /// the exact audio clip behind each transcript line. Written on every
    /// (re-)transcription; deleted with the bundle; harmless once audio expires.
    public func saveSegments(_ segments: [LabeledSegment], for meetingID: String) throws {
        let url = try directory(for: meetingID).appendingPathComponent("segments.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(segments).write(to: url, options: .atomic)
    }

    /// The saved labeled segments, or nil for meetings transcribed before
    /// `segments.json` existed (or an unreadable file).
    public func segments(for meetingID: String) -> [LabeledSegment]? {
        let url = bundleURL(for: meetingID).appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LabeledSegment].self, from: data)
    }
```

In `MeetingProcessor.process`, immediately after `try store.saveTranscript(transcript, for: recording.meeting.id)`:

```swift
        // Persist the fused segments so each transcript line can be played back
        // (speaker verification). Best-effort: a failure only disables playback.
        try? store.saveSegments(labeled, for: recording.meeting.id)
```

- [ ] **Step 4: Run tests** — `swift test --filter "MeetingStore segments"` → PASS; full `swift test` → PASS.

- [ ] **Step 5: Commit** — `feat: persist fused segments as segments.json for line playback`

---

### Task 3: `TranscriptAudioLocator` (pure)

**Files:**
- Create: `Sources/MeetingKit/TranscriptAudioLocator.swift`
- Test: `Tests/MeetingKitTests/TranscriptAudioLocatorTests.swift` (create)

**Interfaces:**
- Consumes: `TranscriptParser.Turn` (`time: String` like `"14:53:02"` or `"00:05"`, `speaker`, `text`); `LabeledSegment` (Task 1); `TranscriptFormatter.timestamp(_:baseDate:timeZone:)` (internal, same module — renders `HH:mm:ss` wall clock when baseDate set).
- Produces:

```swift
public enum TranscriptAudioLocator {
    public struct ClipLocation: Equatable, Sendable {
        public let fileName: String
        public let start: TimeInterval  // seconds into the file
        public let end: TimeInterval
    }
    /// One entry per turn (nil = no playable clip for that line).
    public static func locate(
        turns: [TranscriptParser.Turn],
        segments: [LabeledSegment]?,
        recordedAt: Date,
        localUserName: String,
        micFileName: String,
        systemFileName: String,
        timeZone: TimeZone = .current
    ) -> [ClipLocation?]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("TranscriptAudioLocator")
struct TranscriptAudioLocatorTests {
    let tz = TimeZone(identifier: "Australia/Sydney")!
    // 2026-07-07 14:00:00 AEST
    var recordedAt: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 14))!
    }
    func turn(_ time: String, _ speaker: String) -> TranscriptParser.Turn {
        TranscriptParser.Turn(time: time, speaker: speaker, text: "…")
    }
    func locate(
        _ turns: [TranscriptParser.Turn], segments: [LabeledSegment]?,
        recordedAt: Date? = nil
    ) -> [TranscriptAudioLocator.ClipLocation?] {
        TranscriptAudioLocator.locate(
            turns: turns, segments: segments, recordedAt: recordedAt ?? self.recordedAt,
            localUserName: "Yulei Liu", micFileName: "mic.wav",
            systemFileName: "system.wav", timeZone: tz)
    }

    @Test("precise: segments pair by index with exact start/end and channel file")
    func precisePairing() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: .microphone),
            LabeledSegment(start: 9.5, end: 20, text: "…", speaker: "Sam", channel: .system),
        ]
        // Rendered stamps for starts 5s and 9.5s after 14:00:00.
        let turns = [turn("14:00:05", "Yulei Liu"), turn("14:00:09", "Sam")]
        let clips = locate(turns, segments: segments)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
        #expect(clips[1] == .init(fileName: "system.wav", start: 9.5, end: 20))
    }

    @Test("precise: a speaker mismatch at an index falls back for that turn only")
    func sanityCheckFallsBack() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: .microphone),
            LabeledSegment(start: 9.5, end: 20, text: "…", speaker: "Sam", channel: .system),
        ]
        // Second turn's speaker was renamed after processing → mismatch.
        let turns = [turn("14:00:05", "Yulei Liu"), turn("14:00:09", "Dinesh")]
        let clips = locate(turns, segments: segments)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
        // Fallback for turn 1: offset 9s from stamp, last turn → +15s, non-local → system.
        #expect(clips[1] == .init(fileName: "system.wav", start: 9, end: 24))
    }

    @Test("precise: nil segment channel uses the label-based file guess")
    func nilChannelGuess() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: nil)
        ]
        let clips = locate([turn("14:00:05", "Yulei Liu")], segments: segments)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
    }

    @Test("fallback: offsets derive from wall-clock stamps; end is next turn capped at 30s")
    func fallbackOffsets() {
        let turns = [
            turn("14:00:10", "Yulei Liu"),  // next turn 100s later → capped at +30
            turn("14:01:50", "Sam"),  // last turn → +15
        ]
        let clips = locate(turns, segments: nil)
        #expect(clips[0] == .init(fileName: "mic.wav", start: 10, end: 40))
        #expect(clips[1] == .init(fileName: "system.wav", start: 110, end: 125))
    }

    @Test("fallback: midnight wrap adds 24h")
    func midnightWrap() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let lateNight = cal.date(
            from: DateComponents(year: 2026, month: 7, day: 7, hour: 23, minute: 59, second: 30))!
        let clips = locate([turn("00:00:10", "Sam")], segments: nil, recordedAt: lateNight)
        #expect(clips[0] == .init(fileName: "system.wav", start: 40, end: 55))
    }

    @Test("fallback: two-component MM:SS stamps are meeting-relative offsets")
    func relativeStamps() {
        let clips = locate([turn("00:05", "Sam")], segments: nil)
        #expect(clips[0] == .init(fileName: "system.wav", start: 5, end: 20))
    }

    @Test("unparsable or empty stamps yield nil for that turn")
    func unparsableStamp() {
        let clips = locate([turn("", "Sam"), turn("bogus", "Sam")], segments: nil)
        #expect(clips == [nil, nil])
    }

    @Test("segment/turn count mismatch falls back wholesale")
    func countMismatch() {
        let segments = [
            LabeledSegment(start: 5, end: 9, text: "…", speaker: "Yulei Liu", channel: .microphone)
        ]
        let turns = [turn("14:00:05", "Yulei Liu"), turn("14:00:09", "Sam")]
        let clips = locate(turns, segments: segments)
        // Both fall back to stamp-derived windows.
        #expect(clips[0] == .init(fileName: "mic.wav", start: 5, end: 9))
        #expect(clips[1] == .init(fileName: "system.wav", start: 9, end: 24))
    }
}
```

Note on `countMismatch` expectations: fallback end for turn 0 = next turn offset (9) since 9 − 5 < 30.

- [ ] **Step 2: Run to verify failure** — `swift test --filter TranscriptAudioLocatorTests` → compile FAIL.

- [ ] **Step 3: Implement** — create `Sources/MeetingKit/TranscriptAudioLocator.swift`:

```swift
import Foundation

/// Pure mapping from parsed transcript turns to playable audio clips, so the UI
/// can play the exact moment behind a line (speaker verification, R27).
///
/// Precise path: `segments.json` pairs with turns by index (the formatter writes
/// one line per segment, in order), sanity-checked per index by speaker AND the
/// rendered timestamp. Any mismatch degrades that turn (or, on count mismatch,
/// every turn) to the fallback: derive the offset from the turn's wall-clock
/// stamp and guess the file from the label — best-effort by design; in-room
/// named speakers can guess wrong until the meeting is re-transcribed.
public enum TranscriptAudioLocator {

    public struct ClipLocation: Equatable, Sendable {
        public let fileName: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(fileName: String, start: TimeInterval, end: TimeInterval) {
            self.fileName = fileName
            self.start = start
            self.end = end
        }
    }

    /// End of a fallback window: the next turn's start, at most this much later.
    static let maxFallbackClip: TimeInterval = 30
    /// Fallback window for the last turn (no next turn to bound it).
    static let lastTurnClip: TimeInterval = 15

    public static func locate(
        turns: [TranscriptParser.Turn],
        segments: [LabeledSegment]?,
        recordedAt: Date,
        localUserName: String,
        micFileName: String,
        systemFileName: String,
        timeZone: TimeZone = .current
    ) -> [ClipLocation?] {
        // Fallback offsets are shared by both paths (per-turn degradation).
        let offsets = turns.map { offset(of: $0.time, recordedAt: recordedAt, timeZone: timeZone) }
        let usable = (segments?.count == turns.count) ? segments : nil

        return turns.indices.map { i in
            let guessedFile =
                turns[i].speaker == localUserName ? micFileName : systemFileName
            if let seg = usable?[i], seg.speaker == turns[i].speaker,
                TranscriptFormatter.timestamp(seg.start, baseDate: recordedAt, timeZone: timeZone)
                    == turns[i].time
            {
                let file: String
                switch seg.channel {
                case .microphone: file = micFileName
                case .system: file = systemFileName
                case nil: file = guessedFile
                }
                return ClipLocation(fileName: file, start: seg.start, end: seg.end)
            }
            // Fallback: stamp-derived window.
            guard let start = offsets[i] else { return nil }
            let end: TimeInterval
            if i + 1 < turns.count, let next = offsets[i + 1], next > start {
                end = min(next, start + maxFallbackClip)
            } else {
                end = start + lastTurnClip
            }
            return ClipLocation(fileName: guessedFile, start: start, end: end)
        }
    }

    /// Meeting-relative offset of a rendered stamp. "HH:mm:ss" is wall-clock
    /// (the formatter always renders with baseDate): offset = stamp − recordedAt's
    /// clock time, +24 h on midnight wrap. "MM:SS" is already an offset.
    static func offset(of stamp: String, recordedAt: Date, timeZone: TimeZone) -> TimeInterval? {
        let parts = stamp.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), !parts.isEmpty else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2:  // "MM:SS" — meeting-relative (legacy relative rendering)
            return TimeInterval(values[0] * 60 + values[1])
        case 3:  // "HH:mm:ss" — wall clock
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let base = cal.dateComponents([.hour, .minute, .second], from: recordedAt)
            let stampSeconds = values[0] * 3600 + values[1] * 60 + values[2]
            let baseSeconds =
                (base.hour ?? 0) * 3600 + (base.minute ?? 0) * 60 + (base.second ?? 0)
            var offset = stampSeconds - baseSeconds
            if offset < 0 { offset += 24 * 3600 }  // crossed midnight
            return TimeInterval(offset)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter TranscriptAudioLocatorTests` → PASS; full `swift test` → PASS.

- [ ] **Step 5: Commit** — `feat: TranscriptAudioLocator maps transcript lines to audio clips`

---

### Task 4: `ClipPlayer` + hover play button in the transcript view

**Files:**
- Create: `Sources/MeetingAssistant/ClipPlayer.swift`
- Modify: `Sources/MeetingAssistant/AppState.swift` (two small accessors near `transcript(for:)`, ~line 505)
- Modify: `Sources/MeetingAssistant/MainWindowView.swift` (`MeetingDetailView` body where `TranscriptReadingView` is constructed, ~line 425; `TranscriptReadingView` itself, ~line 635)

**Interfaces:**
- Consumes: `TranscriptAudioLocator.locate(...)` (Task 3), `MeetingStore.segments(for:)` (Task 2), existing `state.hasAudio(for:)`, `recording.micAudioFile`/`.systemAudioFile` (file names within the bundle), `TranscriptParser.parse`.
- Produces: app-target wiring only; no MeetingKit changes. App-target code has NO unit tests — gate is `swift build` + full suite green.

- [ ] **Step 1: Create `Sources/MeetingAssistant/ClipPlayer.swift`**

```swift
import AVFoundation
import Foundation

/// Plays one transcript-line clip at a time (speaker verification, R27).
/// Starting a new clip stops the current one; the view highlights whichever
/// turn id is playing. Failures just reset to stopped — playback is auxiliary.
@MainActor
final class ClipPlayer: ObservableObject {
    @Published private(set) var playingTurnID: Int?

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(url: URL, from start: TimeInterval, to end: TimeInterval, turnID: Int) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url), end > start else { return }
        self.player = player
        player.currentTime = start
        guard player.play() else {
            self.player = nil
            return
        }
        playingTurnID = turnID
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((end - start) * 1_000_000_000))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingTurnID = nil
    }
}
```

- [ ] **Step 2: AppState accessors** — in `Sources/MeetingAssistant/AppState.swift`, next to `transcript(for:)`:

```swift
    /// Saved fused segments for exact line playback, or nil for recordings
    /// transcribed before segments.json existed.
    func savedSegments(for recording: MeetingRecording) -> [LabeledSegment]? {
        store.segments(for: recording.meeting.id)
    }

    /// The meeting bundle directory holding mic.wav / system.wav.
    func audioDirectory(for recording: MeetingRecording) -> URL? {
        try? store.directory(for: recording.meeting.id)
    }
```

- [ ] **Step 3: Wire the view** — in `MeetingDetailView` (MainWindowView.swift), add `@StateObject private var clipPlayer = ClipPlayer()` and pass playback context to `TranscriptReadingView`:

```swift
                TranscriptReadingView(
                    document: state.transcript(for: recording),
                    localUserName: state.settings.localUserName,
                    playback: playbackContext
                )
```

with, in `MeetingDetailView`:

```swift
    /// Everything the reading view needs to play a line, or nil when the audio
    /// is gone (retention) — the play buttons don't render at all then.
    private var playbackContext: TranscriptReadingView.Playback? {
        guard state.hasAudio(for: recording),
            let dir = state.audioDirectory(for: recording)
        else { return nil }
        return TranscriptReadingView.Playback(
            segments: state.savedSegments(for: recording),
            recordedAt: recording.recordedAt,
            audioDirectory: dir,
            micFileName: recording.micAudioFile,
            systemFileName: recording.systemAudioFile,
            player: clipPlayer
        )
    }
```

Also stop playback when the selection changes: on `MeetingDetailView` add `.onDisappear { clipPlayer.stop() }` and `.onChange(of: recording.meeting.id) { clipPlayer.stop() }` (attach to the view's top-level container).

- [ ] **Step 4: TranscriptReadingView** — extend it (keep existing rendering; parameter defaults keep other call sites compiling):

```swift
private struct TranscriptReadingView: View {
    let document: String?
    let localUserName: String
    var playback: Playback? = nil

    struct Playback {
        let segments: [LabeledSegment]?
        let recordedAt: Date
        let audioDirectory: URL
        let micFileName: String
        let systemFileName: String
        let player: ClipPlayer
    }
    ...
```

In `body`, after `let parsed = TranscriptParser.parse(document ?? "")`, compute clips once:

```swift
        let clips: [TranscriptAudioLocator.ClipLocation?] =
            playback.map { p in
                TranscriptAudioLocator.locate(
                    turns: parsed.turns, segments: p.segments, recordedAt: p.recordedAt,
                    localUserName: localUserName, micFileName: p.micFileName,
                    systemFileName: p.systemFileName)
            } ?? Array(repeating: nil, count: parsed.turns.count)
```

Where each turn row renders (the `ForEach` over `parsed.turns` — use `Array(parsed.turns.enumerated())`, id: `\.offset` if not already indexed), wrap the timestamp area so hovering shows the control. Add to the row's leading timestamp column:

```swift
    /// Hover play/stop for one turn. Only rendered when a clip exists.
    @ViewBuilder
    private func playControl(index: Int, clip: TranscriptAudioLocator.ClipLocation?) -> some View {
        if let clip, let playback {
            let isPlaying = playback.player.playingTurnID == index
            Button {
                if isPlaying {
                    playback.player.stop()
                } else {
                    playback.player.play(
                        url: playback.audioDirectory.appendingPathComponent(clip.fileName),
                        from: clip.start, to: clip.end, turnID: index)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isPlaying ? Theme.accent : .secondary)
            .help(isPlaying ? "Stop" : "Play this line")
            .opacity(isPlaying || hoveredTurn == index ? 1 : 0)
        }
    }
```

with row-level state `@State private var hoveredTurn: Int?` set via `.onHover { hovering in hoveredTurn = hovering ? index : (hoveredTurn == index ? nil : hoveredTurn) }` on the row, the row highlighted while playing:

```swift
            .background(
                playback?.player.playingTurnID == index
                    ? Theme.accent.opacity(0.08) : Color.clear
            )
```

and `@ObservedObject` plumbing: because `Playback` is a plain struct, observe the player in the view via a nested row view or by holding `@ObservedObject var player: ClipPlayer` where needed — simplest is a small `TurnRowAccessory: View` struct that takes `@ObservedObject var player: ClipPlayer` so SwiftUI re-renders on `playingTurnID` changes. The implementer chooses the minimal structure that (a) re-renders on playingTurnID change, (b) keeps existing text layout untouched.

- [ ] **Step 5: Build + full tests** — `swift build && swift test` → both green (no unit tests for this task's code).

- [ ] **Step 6: Commit** — `feat: hover play button on transcript lines (speaker verification)`

---

### Task 5: REQUIREMENTS.md — R27

**Files:**
- Modify: `REQUIREMENTS.md` (Transcripts/history section, after R22/R26 block — insert as a new bullet in "Transcripts, history & management")

- [ ] **Step 1: Insert the requirement** (after the last R2x bullet in the "Transcripts, history & management" section):

```markdown
- **R27 — Verify a speaker by ear.** Hovering a transcript line reveals a play
  button that plays that line's audio, so the user can check who is really
  speaking before renaming (R8/R9). Meetings transcribed from now on store
  exact per-line clip boundaries (`segments.json`); older recordings play a
  best-effort window derived from the line's timestamp (and may guess the wrong
  channel for in-room named speakers) until re-transcribed. The control is
  absent once retention has expired the audio (R22), like "Transcript Again".
```

- [ ] **Step 2: Full test run** — `swift test` → PASS.

- [ ] **Step 3: Commit** — `docs: R27 verify a speaker by ear`

---

## Self-review notes

- Spec coverage: channel field (T1), segments.json write/read + processor (T2), locator precise/fallback/midnight/caps/channel-guess (T3), player + hover UI + retention gate + stop-on-switch (T4), R27 (T5). ✔
- Type consistency: `ClipLocation(fileName:start:end:)`, `locate(turns:segments:recordedAt:localUserName:micFileName:systemFileName:timeZone:)`, `ClipPlayer.play(url:from:to:turnID:)`/`stop()`/`playingTurnID: Int?`, `Playback` struct fields used identically in Tasks 3–4. ✔
- Task 4 intentionally gives the implementer freedom on the exact SwiftUI observation structure (marked as such) — the acceptance criteria are behavioral, not structural.
