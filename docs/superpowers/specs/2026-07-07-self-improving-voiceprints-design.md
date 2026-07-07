# Self-improving voiceprints (multi-sample known speakers)

**Date:** 2026-07-07
**Status:** Approved
**Branch:** `feature/multi-sample-voiceprints` (builds on `fix/voice-match-hardening`)

## Problem

A known speaker's voiceprint is a single embedding, and `SpeakerLibrary.upsert`
**replaces** it wholesale on every rename. Consequences observed in production:

- Prints reflect one meeting's mic/room/headset, so a person's real voice can sit
  0.2+ away from their own print (the local user's cluster missed the margin gate
  and fell to "Speaker 2").
- One rename on a bad cluster wipes a good print (how "Larry Song" and
  "Joshua Li" became contaminated).
- The library never gets better on its own; most meetings teach nothing.

Requirement: *voiceprints should self-improve — the more voice the app has for a
user, the better the prints.*

## Design

### Data model

`KnownSpeaker` drops its single `embedding: [Float]` for:

```swift
public struct VoiceSample: Codable, Sendable, Equatable {
    public var embedding: [Float]   // one voice-mode centroid
    public var seconds: TimeInterval // speech behind this sample
    public var addedAt: Date
}
// KnownSpeaker.samples: [VoiceSample]  (1...8 entries)
```

Legacy library entries (single `embedding`, no `samples`) migrate on decode: the
old embedding becomes one sample with `seconds = 30` (one enrollment's worth) so
an old print is neither lost nor instantly outweighed.

### Matching

Distance from a diarized cluster to a known speaker = **minimum cosine distance
across the speaker's samples** (match whichever version of their voice is
closest). Everything else in `SpeakerRecognizer` is unchanged: threshold 0.40,
margin 0.10 vs the nearest *different* speaker, the 15 s minimum-speech gate
(`minSpeechDuration`), and one-name-one-cluster dedup.

### Learning

Two feed points, both trusted-only:

1. **Explicit rename** (`AppState.renameSpeaker`) — already gated on the cluster
   clearing 15 s (`MeetingSpeakerMap.learnableVoiceprint`).
2. **Auto-refinement after each meeting** — clusters whose resolved label matches
   a library name (they passed distance + margin + duration to get that label)
   are folded in automatically once processing saves the speaker map.

Learning **adds a sample**; it never mutates existing ones, so a bad sample can't
corrupt a good one. Bounded at **8 samples per speaker**: when full, the two
*closest* samples among existing + incoming merge via duration-weighted average.
Merge-closest preserves voice-mode diversity (a rare meeting-room sample
survives; two near-identical headset samples collapse), unlike drop-oldest which
forgets the regular setup after a string of one-offs.

`SpeakerLibrary.upsert` keeps replace-all semantics for deliberate resets
(re-recording enrollment); `learn` is the additive path.

### Components (pure, TDD, in MeetingKit)

| Unit | Responsibility |
| --- | --- |
| `VoiceSample` | Codable sample; `KnownSpeaker.samples` + legacy decode migration |
| `VoicePrint.distance(_:to:)` | min cosine distance over samples (∞ for empty) |
| `VoicePrint.adding(_:to:cap:)` | append, or merge the closest pair when at cap |
| `SpeakerLibrary.learn(name:embedding:seconds:isMe:)` | add sample to entry (create if new) |
| `LibraryRefinement.updates(map:known:)` | (label, embedding, seconds) list to auto-learn from a saved meeting map |
| `SpeakerRecognizer.bestMatch` | switches from single-embedding to `VoicePrint.distance` |

`AppState` wiring stays thin: call `learn` from `renameSpeaker`; apply
`LibraryRefinement.updates` after a meeting finishes processing.

### Error handling

- Empty/mismatched-length embeddings: `VoicePrint.distance` returns ∞ (existing
  `VoiceMatch.cosineDistance` semantics); `learn` ignores unusable embeddings.
- Library file unreadable → existing behavior (start empty) unchanged.

### Accepted limitations

- "Make Again" on a meeting re-learns the same audio once more; bounded by the
  8-sample cap and merge behavior. Not worth tracking learned-meeting IDs yet.
- Samples are per-speaker voice *modes*, not per-device labels; no UI to inspect
  individual samples (delete-speaker remains the reset).

## Testing

- Blend/merge math, cap behavior, min-distance matching, legacy decode, `learn`
  accumulation, and `LibraryRefinement` are all pure — swift-testing suites for
  each, written first (TDD).
- Existing `SpeakerRecognizerTests` keep passing with samples of one element
  (equivalence with today's behavior).

## Requirements impact

- **R9 (cross-meeting recognition)** gains the self-improvement clause.
- **R10 (conservative matching)** unchanged in spirit; distance is now
  min-over-samples.
- New: **R9c — Self-improving voiceprints.** Every confidently-attributed
  cluster (match or rename) enriches that speaker's print; more voice ⇒ better
  recognition, without any user action.
