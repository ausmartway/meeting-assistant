# Remote-speaker voiceprint identification — design

**Date:** 2026-06-26
**Status:** Approved (brainstorming)
**Builds with:** the window-scoped OCR capture change (same branch). Independent
code paths; shipped together.

## Problem

When several remote people share one far-end endpoint (a conference room or a
device), the meeting UI shows that tile's **room/device** name — "Boardroom",
"Poly Studio X50", "Meeting Room 3" — not a person. OCR faithfully reads that
name, but it's useless for telling the people in that room apart: every remote line
from that endpoint gets the same non-human label.

## Goal

When the on-screen active-speaker name is **not confidently a real human name**,
identify the remote speaker by **voice fingerprint** instead — reusing the
diarization + speaker-library machinery already used on the mic channel, now
applied to the **system-audio** (remote) channel. Only confident human on-screen
names are trusted as-is; voiceprints are the fallback whenever unsure.

Cost is paid lazily: the system channel is diarized **only when at least one
on-screen active-speaker name is not confidently human** (a room/device name, or an
ambiguous string). Meetings where every remote name reads as a clear person stay
exactly as cheap as today.

## Principles preserved

- **Cheap live capture, heavy post-processing.** All of this runs in
  `MeetingProcessor` post-processing; the live path is untouched.
- **Conservative voiceprint matching (R10).** Reuses `SpeakerRecognizer` unchanged
  (threshold + margin); unrecognized remote clusters become anonymous "Speaker N",
  never a guessed name.
- **Pure logic is unit-tested.** The classifier, the numbering change, and the
  fusion change are pure and tested; the diarizer wiring is exercised via the
  existing `StubDiarizer`-based `MeetingProcessor` tests.

## Components

### 1. `HumanNameClassifier` — new pure module

```swift
public enum HumanNameClassifier {
    /// True ONLY when `name` is confidently a person's name. Anything ambiguous —
    /// including room/device names — returns false, so the caller defaults to
    /// voiceprints whenever unsure.
    static func isHumanName(_ name: String) -> Bool
}
```

**Bias: confident-human-only.** Per the decision to *default to voiceprints
whenever unsure*, `isHumanName` returns `true` only when the name positively
matches a human-name shape **and** carries none of the non-human signals.
Everything else — room/device names *and* anything the classifier can't confidently
call a person — returns `false`.

Non-human signals (any one ⇒ `false`):
- room/meeting keywords (EN: room, conference, huddle, boardroom, meeting, board,
  studio, lab, rally, office; CJK: 会议室 / 會議室 / 会议 / 會議 / 室),
- device/brand tokens (poly, logitech, cisco, webex, owl, neat, crestron, rally
  bar, tap),
- contains digits (e.g. "Room 3", "MTR-204"),
- an ALL-CAPS token of length ≥ 3 (device IDs),
- more than 3 whitespace-separated tokens.

Positive human shape (required for `true`): 1–3 tokens, each an alphabetic
capitalized word with no digits/keywords; **or** a short CJK name (2–4 chars)
without a room marker. A name that matches no non-human signal but also doesn't fit
the human shape (e.g. a lone lowercase token, an emoji handle, gibberish) is
**not** confidently human → `false` → voiceprints.

Unit-tested: "John Smith" / "李伟" → human; "Boardroom" / "Poly Studio X50" /
"Meeting Room 3" / "会议室 A" → non-human; ambiguous ("guest", "x", "🎤", a 5-word
string) → non-human (defaults to voiceprints).

**Cost note:** this strict bias means system diarization triggers whenever *any*
remote name is even ambiguous, not only for obvious room/device names — accepted in
exchange for not mis-attributing an uncertain name. Confident human names ("John
Smith") still skip the expensive pass.

### 2. Unified "Speaker N" numbering — `SpeakerRecognizer.resolve`

Add `startingAnon: Int = 2` (default keeps today's behavior). When resolving the
**system** clusters, pass `startingAnon` past the highest number the mic pass used,
so mic and remote anonymous speakers never collide ("Me", "Speaker 2", "Speaker 3"
for mic; "Speaker 4"… for remote). Computed as
`2 + (number of "Speaker N" labels the mic pass produced)`.

### 3. `SpeakerFuser.fuse` — voiceprint fallback for remote segments

New optional params `systemDiarization: [DiarizedSpan] = []`,
`systemLabels: [String: String] = []`. For a `.system` segment at midpoint `t`:

```
let ocr = activeSpeaker(at: t, in: timeline)
if let ocr, HumanNameClassifier.isHumanName(ocr) {
    speaker = ocr                                   // trust a human on-screen name
} else if let span = span(at: t, in: systemDiarization),
          let label = systemLabels[span.speakerID] {
    speaker = label                                 // voiceprint: known name or "Speaker N"
} else {
    speaker = unknownLabel                          // non-human/nil + no voiceprint → "Speaker"
}
```

With no system diarization supplied (the lazy default), this reduces to: human name
→ use it; otherwise `unknownLabel` — i.e. today's behavior, except a non-human room
name no longer leaks onto the transcript (it degrades to "Speaker"). Mic-segment
handling is unchanged.

### 4. `MeetingProcessor` — trigger, diarize, resolve, fuse, persist

After transcription and OCR-timeline consolidation, before fusion:

1. **Detect need.** Scan `.system` segments; for each, look up the consolidated
   OCR name at its midpoint. If any non-nil name fails
   `HumanNameClassifier.isHumanName`, set `needsRemoteDiarization`.
2. **Diarize lazily.** If needed, `diarizer.diarize(audioFile: systemURL,
   progress:)` → `systemOutcome` (with progress reporting per R21 and a
   `Task.checkCancellation()` checkpoint, mirroring the mic pass).
3. **Resolve.** `systemLabels = SpeakerRecognizer.resolve(outcome: systemOutcome,
   knownSpeakers:, startingAnon: 2 + micAnonCount)`.
4. **Fuse.** Pass `systemDiarization: systemOutcome.spans` and `systemLabels` into
   `SpeakerFuser.fuse`.
5. **Persist.** Merge the system clusters into the per-meeting `MeetingSpeakerMap`
   (namespacing system cluster ids, e.g. `"sys:<id>"`, so they can't collide with
   mic cluster ids; labels are already unique via unified numbering). No schema
   change — the existing flat map and the label-keyed `relabel` rename flow work
   unchanged, so a remote "Speaker N" can be renamed and its voiceprint taught to
   the library for cross-meeting recognition (R8/R9).

When `needsRemoteDiarization` is false, none of steps 2–5's remote work runs and
`fuse` is called exactly as today.

## Data flow

```
system segments + consolidated OCR timeline
   │  any OCR name non-human?  (HumanNameClassifier)
   ├─ no  → fuse as today (human names / "Speaker")
   └─ yes → diarize system.wav → SpeakerRecognizer.resolve (startingAnon offset)
            → fuse: human OCR name wins; else voiceprint label; else "Speaker"
            → merged speaker map persisted (mic ∪ sys:* clusters)
```

## Edge cases

- **Mic pass empty** (single local speaker, no in-room others): `micAnonCount = 0`,
  remote numbering starts at "Speaker 2".
- **Remote cluster matches an enrolled remote person:** gets their name (R9).
- **A system cluster matches the `isMe` print** (echo bleed-through): rare; treated
  like any match. Echo cancellation normally removes local voice from system audio;
  not specially handled.
- **Non-human name but diarization finds no span at `t`** (silence/gap): falls to
  `unknownLabel`.
- **Mixed endpoint:** some remote tiles human-named, one room tile non-human → the
  presence of the one non-human name triggers system diarization; human-named
  segments still use their OCR name (first branch), room segments use voiceprints.

## Testing

New/updated swift-testing (pure):
- `HumanNameClassifier.isHumanName` — human vs room/device cases above (EN + CJK,
  digits, ALL-CAPS, long strings).
- `SpeakerRecognizer.resolve` — `startingAnon` offsets anonymous numbering; default
  unchanged (existing tests stay green).
- `SpeakerFuser` — system segment with a human OCR name uses it; with a non-human
  name uses the system voiceprint label; with non-human + no span uses
  `unknownLabel`; mic behavior unchanged.
- `MeetingProcessor` (via `StubDiarizer`, mirroring `MeetingProcessorDiarizationTests`):
  a non-human OCR name triggers system diarization and remote labels appear;
  all-human names skip system diarization.

Integration (run the app): real FluidAudio diarization of the system channel,
progress/cancellation, and the merged speaker-map rename flow.

## Requirements impact

New requirement: **remote speakers in a shared room/device are identified by
voiceprint when the on-screen name isn't a real person's name.** Flag for
`requirements-sync-reviewer`.

## Build order

1. `HumanNameClassifier` (+ tests).
2. `SpeakerRecognizer.resolve` `startingAnon` param (+ tests; defaults keep
   existing tests green).
3. `SpeakerFuser` system voiceprint fallback (+ tests).
4. `MeetingProcessor`: trigger scan + lazy system diarization + resolve + fuse
   wiring + merged speaker-map persistence (+ StubDiarizer test).
5. REQUIREMENTS.md note + requirements-sync check.
