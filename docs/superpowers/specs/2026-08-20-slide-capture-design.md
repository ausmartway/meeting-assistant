# Slide capture — capture shared screens during a presentation (R28) — design

**Requirement:** R28 (new) — when someone presents, capture keyframes of the shared
screen and anchor them into the transcript
**Date:** 2026-08-20
**Status:** Approved, ready for implementation plan

## Problem

`CaptureSession` already runs a video stream on the meeting window at ~2 fps and hands
one frame every 2.5 s to `SpeakerSampler` for active-speaker OCR. Those pixels are then
**discarded** — nothing is ever persisted. So a presented deck, a walked-through
dashboard, or a shared architecture diagram flows past the app and is lost, leaving a
transcript that reads "so this is the architecture we landed on" with no way to know
what was on screen.

The screen-share content is already inside the frames we sample. The work is deciding
*which* frames are worth keeping, persisting them cheaply, and anchoring them into the
transcript at the right point in the conversation.

Two existing constraints shape the whole design:

- **N2 (cheap live capture, heavy post-processing)** — whatever runs during the meeting
  must stay light. The mic + system audio path is the load-bearing signal and must not
  be disturbed.
- **N1 / N1b (local-first, and the recorded participants' privacy)** — a shared screen
  is a *distinct and higher* sensitivity class than speech. A customer's prod dashboard,
  CRM, or inbox can appear on it.

## Decisions (settled in brainstorming)

- **Output form:** slide **keyframe images**, anchored inline in the transcript at the
  timestamp where they appeared. No OCR of slide text in this iteration.
- **Default:** **on by default**, with a single Settings toggle to turn it off.
- **Whose screen:** the **meeting window only** — the stream that already exists. Nothing
  outside the meeting window is ever written to disk, and no new capture surface or
  permission is introduced. The user's *own* share is captured only incidentally, when
  the conferencing app happens to echo it back into the meeting window (Google Meet
  renders a self-preview; Zoom does not, and often minimizes the meeting window during a
  share, which stops video capture entirely via the existing `onScreenWindowsOnly: true`
  behavior). Deliberately accepted: it is best-effort, at whatever fidelity the app
  echoes.
- **Retention:** slides live **with the transcript** (default 1-year window), not with the
  audio (default 7 days). The transcript is anchored to them; expiring them early leaves
  holes in a document the user chose to keep.
- **Detection strategy:** **change-then-settle on frame signatures** — no Vision, no
  per-app knowledge. See "Detection" below for the two rejected alternatives.

## Non-goals

- **OCR of slide text.** Deferred, not rejected: the images are on disk, so a later pass
  can add searchable text without redesign.
- **Capturing the display when the user presents.** Rejected for this iteration: it would
  put Slack, mail, and other tabs into the bundle and would break the "only the meeting
  window is ever recorded" property.
- **Post-meeting Vision pruning of non-presentation keyframes.** Deferred. Because
  candidates land on disk, this can be added later without touching the live path.
- **Video recording of the share.** Out of scope; keyframes only.

## Detection

### The rule: change-then-settle

Every sampled frame (the one already thrown at `SpeakerSampler`, every 2.5 s) is reduced
to a **16×16 grey signature**. A frame is saved as a keyframe when both hold:

1. It **barely differs from the previous sample** — the picture is holding still.
2. It **differs materially from the last keyframe saved** — this is genuinely new content.

Talking heads never hold still; webcam noise alone moves every pixel between samples. A
slide, a document, a dashboard, or an IDE holds perfectly still. So "holds still" is the
discriminator, and it costs one small CoreImage render per sample.

Deciding on the *current* frame (rather than confirming the previous one) means no pixel
buffer or encoded JPEG is ever held between samples. The cost is that a slide is stamped
up to 2.5 s after it appeared — irrelevant for a slide that is up for minutes.

### Failure modes, and why they are acceptable

| Situation | Behavior | Verdict |
|---|---|---|
| Static slide / doc / dashboard | Saved once per change | Intended |
| Talking-head gallery | Never still → nothing saved | Intended |
| Shared **video** playing | Constant motion → skipped | Correct; a video is not a slide |
| Gallery with all cameras off | Static → one keyframe on layout change | Harmless |
| A participant's camera freezes | Could yield one face keyframe | Rare, single frame |

### Alternatives rejected

- **Classify live with Vision** (face detection + text density per sample). More directly
  answers "is this a presentation", but triples live Vision work against N2, and a
  misclassification loses the frame permanently in the one path that cannot be retried.
- **Save every change live, prune with Vision post-meeting.** Highest recall and
  re-tunable, but writes participants' faces to disk specifically to delete them minutes
  later, and churns the most disk. Retained as the deferred upgrade path if real meetings
  produce junk keyframes.

## Architecture

### 1. `SlideChangeDetector` (MeetingKit, new, pure)

The entire decision rule, with no framework dependencies, so every branch is reachable
from a unit test with hand-written `[UInt8]` — no meeting, display, or permission needed.

```swift
public struct FrameSignature: Equatable, Sendable {
    public let cells: [UInt8]   // 16×16 grey, row-major
}

public struct SlideChangeDetector {
    public var stillThreshold: Double = 0.02    // vs. previous sample → "holding still"
    public var changeThreshold: Double = 0.10   // vs. last keyframe → "genuinely new"
    public var minInterval: TimeInterval = 5    // floor between keyframes
    public var maxKeyframes: Int = 300          // per-meeting cap

    public mutating func consider(_ signature: FrameSignature, at t: TimeInterval) -> Bool
}
```

State held: previous signature, last-keyframe signature, last-keyframe time, count.
Difference metric: mean absolute difference across cells, normalized to 0...1.

The first sample has no predecessor, so it **skips** rather than saving whatever the
window happened to show at second zero.

### 2. `SlideRecorder` (MeetingKit, new, `actor`)

Thin, framework-touching, and not unit tested — the same role `SpeakerSampler` plays for
names. Owns the detector, a shared `CIContext`, the output directory, and the accumulated
`[SlideKeyframe]`.

```swift
public actor SlideRecorder {
    public init(directory: URL, detector: SlideChangeDetector = .init())
    public func consider(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval)
    public func keyframes() -> [SlideKeyframe]
}
```

`consider` computes the signature, asks the detector, and on a save encodes JPEG
(quality 0.7, at the frame's existing resolution — already capped to a 1920 px long side
by `CaptureSession.captureSize`) and writes it. **Actor isolation is load-bearing**: the
rule depends on sample *order*, and actor serialization provides that without a lock.
Frames arrive 2.5 s apart and processing takes ~10 ms, so no backlog forms.

### 3. `CaptureSession` changes (surgical)

- `public var capturesSlides: Bool = true` — set by `AppState` from settings.
- Inside the `Task` that `handleVideoFrame` **already spawns** for `SpeakerSampler`, add
  `await recorder?.consider(pixelBuffer, at: elapsed)`.
- In `stop()`, fold `await recorder?.keyframes()` into the saved `MeetingRecording`,
  exactly as `samples` already becomes `SpeakerTimeline`.

**The invariant to protect.** `outputQueue` (`CaptureSession.swift:41`) is a **serial**
queue, and *both* stream outputs are registered on it — system audio at
`CaptureSession.swift:297`, screen frames at `CaptureSession.swift:327`. So
`handleSystemAudio` and `handleVideoFrame` can never run concurrently; each waits behind
the other. Today `handleVideoFrame` does only microseconds of work there before handing
off to a `Task`.

Doing signature computation or JPEG encoding **inline on that queue** would back-pressure
audio delivery. ScreenCaptureKit sheds samples when a client's handler queue backs up,
and `handleSystemAudio` writes via `AVAudioFile.write(from:)`, which **appends** with no
notion of the buffer's timestamp. So a shed sample does not leave a silent gap — it makes
`system.wav` *shorter than wall-clock*, shifting every later word earlier and
desynchronizing it from the separately-captured mic channel. That corrupts speaker
fusion, the `[HH:mm:ss]` timestamps, R27 click-to-play, and the slide anchors themselves,
silently, with nothing thrown or logged.

Probability is low (~1% duty cycle, and SCK buffers internally), but the *tail* is the
concern, not the average: `CIContext` work is GPU-backed and occasionally far exceeds its
median — first-use setup, thermal throttling, or contention with WhisperKit, which **R2
explicitly permits to be transcribing an earlier meeting while this one records**. A
two-hour meeting runs this path ~2,900 times. Staying inside the existing `Task` costs
nothing, so there is no tradeoff to weigh — but the reason must survive in the code as a
comment, not just here.

### 4. `Models.swift`

```swift
public struct SlideKeyframe: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval  // seconds from meeting start
    public let file: String             // "slides/slide-0391.jpg"
}
```

`MeetingRecording` gains `slides: [SlideKeyframe]`. It is a timestamped series produced
during capture — precisely what `SpeakerTimeline` is — so the manifest belongs in
`recording.json` rather than a separate file. A custom `init(from:)` uses
`decodeIfPresent(…) ?? []` so every existing `recording.json` still decodes; this mirrors
the back-compat move already used for `MeetingSpeakerMap.durationByCluster`.

### 5. On-disk layout

```
<AppSupport>/MeetingAssistant/<meeting-id>/
  ├── recording.json     ← gains `slides: [{timestamp, file}]`
  ├── mic.wav
  ├── system.wav
  ├── slides/            ← NEW — slide-0391.jpg (zero-padded seconds offset)
  ├── segments.json
  └── transcript.md
```

Filenames are derived from the whole-second offset, making them deterministic and
naturally sortable. Collisions are impossible given the 5 s `minInterval`.

Sizing: ~100–250 KB per keyframe; a typical presentation-heavy hour yields 30–60
keyframes (≈3–15 MB), against ~230 MB of audio for the same meeting. The 300-keyframe cap
bounds the worst case at roughly 45 MB.

### 6. Transcript format — `TranscriptFormatter` (pure)

`document(meeting:segments:baseDate:note:slides:)` gains one parameter defaulted to `[]`,
so all existing call sites and tests compile unchanged. A slide at offset *t* is emitted
after the last turn whose start ≤ *t* — computed from **numbers**, since the formatter
already holds numeric segment starts.

```markdown
**[10:31:04] Yulei:** so this is the architecture we landed on

![Shared screen 10:31:07](slides/slide-0391.jpg)

**[10:31:22] Ada:** where does the worker sit?
```

Real Markdown: the exported `.md` renders images in any viewer that has the folder beside
it, and degrades to alt text where it does not. Ordering is decided once on the write
side; the file's line order carries it from then on.

### 7. Reading side — `TranscriptParser` (pure)

Slide lines are collected into a **separate** list, leaving `turns` byte-identical:

```swift
public struct Slide: Equatable, Sendable {
    public let time: String        // "10:31:07"
    public let file: String        // "slides/slide-0391.jpg"
    public let afterTurnIndex: Int // -1 = before the first turn
}
public let slides: [Slide]         // added to Parsed
```

**Why `turns` must not change.** `TranscriptAudioLocator.locate` gates on
`groups?.count == turns.count` (`TranscriptAudioLocator.swift:78`) and matches parsed
turns **positionally** against the groups from `segments.json`. Parsing slide lines into
`turns` would break that equality and silently downgrade *every* line in the meeting from
an exact segment clip to a stamp-derived window — a quiet R27 regression.

`afterTurnIndex` is `turns.count - 1` at the moment the line is read, which yields `-1`
for free when a slide precedes all speech. Two placement details in `parse`:

- The slide branch must sit **above** the `if turns.isEmpty` header-region block
  (`TranscriptParser.swift:45`) so a slide before the first turn is not mistaken for a
  title or note.
- It must sit **above** the stray-line fallback (`TranscriptParser.swift:58`) that would
  otherwise append the image line into the previous turn's prose.

### 8. Reading view — `MainWindowView`

`TranscriptReadingView` renders turns exactly as today and inserts a slide block after
`afterTurnIndex` (and before the loop for `-1`). The image is capped to the existing
660 pt reading measure, with the Theme's rounded corners and hairline border, captioned
"Shared screen · 10:31:07". Click opens the file in Preview via `NSWorkspace` — native,
and no new window plumbing.

Slides must render **after audio expires**, so their directory cannot hang off `Playback`
(nil by then). It arrives as its own `slidesDirectory: URL?`, sourced from a new
non-creating `MeetingStore.slidesDirectory(for:)` — `directory(for:)` creates on demand
and would resurrect deleted bundles as empty folders, which the store's own comments warn
against.

The word/speaker footer counts `turns` only, so it stays correct with no change.

### 9. Settings

`AppSettings.captureSlides`, default **on** via the `object(forKey:) == nil ? true :
bool(…)` pattern `showDockIcon` already establishes, plus a `Keys.captureSlides` entry. A
toggle labeled "Capture shared screens" with one line of copy naming the tradeoff:
*"Saves a picture whenever a shared screen changes. Kept as long as the transcript."*
`AppState.swift:414` passes it into `CaptureSession.capturesSlides` at construction.

### 10. Retention and storage — no code change

A happy consequence of keeping slides with the transcript:

- `MeetingStore.expireMedia` removes only `mic.wav` and `system.wav`, so slides survive
  audio expiry.
- `bundleSize` / `totalSize` walk directories recursively, so slides are already counted
  in Settings → Storage and the sidebar footer (N11).
- `delete(meetingID:)` and the `transcriptMaxAge` sweep already remove the whole bundle
  directory, slides included.

Only R26's wording needs updating to record the choice.

## The no-presentation case

A meeting where nobody shares produces no `slides/` directory, no manifest entries, and a
`transcript.md` **byte-identical to today's**. The formatter's default parameter makes
that structural rather than something to remember (N5).

## Testing

Every pure piece is TDD'd with swift-testing:

- **`SlideChangeDetectorTests`** — still + different → save; still + same → skip; moving →
  skip; `minInterval` honored; `maxKeyframes` cap enforced; first sample skips (no
  predecessor).
- **`TranscriptFormatterTests`** — interleave position for a mid-conversation slide; slide
  before the first turn; slide after the last turn; `slides: []` reproduces today's exact
  output.
- **`TranscriptParserTests`** — image line → correct `afterTurnIndex`; `turns` identical to
  parsing the same document without slide lines; a malformed `![…` line does not corrupt
  the preceding turn.
- **`MeetingRecording` decoding** — a legacy `recording.json` with no `slides` key decodes
  to `[]`.

`SlideRecorder` and the `CaptureSession` wiring touch ScreenCaptureKit and CoreImage and
are **verified by running** (N8): a real meeting with a remote share, checking that
keyframes appear, faces do not, **both `.wav` files are still full wall-clock length**,
and the reading view interleaves at the right places.

## Risks accepted

- **Disk runaway** — bounded by the 300-keyframe cap (~45 MB/meeting worst case). The
  number is a knob, not a load-bearing guess.
- **A frozen camera feed** reads as "still" and may yield one face keyframe. Rare; the
  deferred Vision prune addresses it if it proves common.
- **The user's own shares** are captured only when the app echoes them, at echo fidelity.
- **Copy to clipboard** pastes Markdown image links that will not resolve in Slack or
  Notion; alt text carries the timestamp.

## REQUIREMENTS.md updates

- **R28 (new)** — Capture shared screens. When the meeting window shows presented content,
  the app saves a keyframe each time that content materially changes, anchored into the
  transcript at the timestamp where it appeared. On by default, one Settings toggle to
  disable. Best-effort and never fatal (N3): only the meeting window is ever captured, so
  the user's own share is caught only when their conferencing app echoes it back.
- **R26 (amend)** — record that captured slides follow the **transcript** retention window,
  not the audio one, and are counted in the storage figures.
- **N1b (amend)** — note that a shared screen is a distinct, higher sensitivity class than
  speech, which is why the capture surface stays limited to the meeting window and the
  feature is a visible, single-toggle setting.
