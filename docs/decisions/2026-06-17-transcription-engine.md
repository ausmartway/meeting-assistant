# Decision record: transcription engine — evaluate Parakeet (FluidAudio) vs WhisperKit

**Date:** 2026-06-17
**Status:** Proposed (spike pending)
**Branch:** `model-finetune`

## Context

The app transcribes meetings on-device with **WhisperKit `whisper-large-v3-turbo`**
(see `CLAUDE.md` → "Transcription backend is swappable behind a protocol"). The
backend is already pluggable behind the `Transcribing` protocol and selected via
`Backends.makeTranscriber(...)`, so swapping engines is a contained change.

Goal (owner priorities, in order): **faster**, then more accurate, then lighter
weight. English is primary; Mandarin is a nice-to-have. On-device/private is a
hard constraint (N1). Raising the macOS floor (currently 14) is acceptable.

A deep, multi-source research pass (20 sources, 25 claims adversarially verified,
22 confirmed) produced the comparison below.

## Options compared

| Engine | Speed (Apple Silicon) | English accuracy | Size / memory | Swift path | Mandarin | License |
|---|---|---|---|---|---|---|
| **Parakeet TDT 0.6B (FluidAudio)** | ~155–190× realtime on ANE (1 hr ≈ 19 s on M4 Pro) | ≥ large-v3-turbo on clean/short English | 0.6B, ANE-only → lower mem | **FluidAudio** Swift 6 / CoreML SDK | v3 multilingual exists; CJK unproven | Apache-2.0 + MIT |
| WhisperKit large-v3-turbo (current) | baseline | baseline | larger | already integrated | strong (current path) | MIT/Apache |
| Apple SpeechAnalyzer (macOS 26) | very fast, zero download/memory | mid-tier (~14% WER earnings — a regression) | built into OS | Swift-native (`CMTimeRange`) | yes | OS built-in |
| SenseVoice-Small | ~15× Whisper-Large (CUDA figure) | strong CJK | small | community MLX/CoreML only | best Mandarin | check |
| Moonshine | edge-fast, advantage vanishes on long-form | Medium ~6.65% | 245M, English-only | native Swift | no | — |

## Decision

**Proposed: make Parakeet TDT 0.6B (via FluidAudio) the primary backend; keep
WhisperKit large-v3-turbo as a fallback — notably for Mandarin.** Subject to the
spike below confirming real-world numbers on a target Mac.

Rationale:
- **Speed (priority #1):** fastest credible on-device option by a wide margin;
  ANE-only leaves the GPU free and uses less memory (good on 16 GB Macs).
- **No English-accuracy regression:** matches or beats large-v3-turbo on English.
- **Low integration effort:** FluidAudio is a production Swift 6 / CoreML SDK
  (Apache-2.0 + MIT, commercial-OK) that fits behind the existing `Transcribing`
  protocol via `Backends`.

Rejected as primary:
- **Apple SpeechAnalyzer** — mid-tier accuracy *and* forces a macOS 14 → 26 jump.
  Reasonable later as an *optional* secondary, not the default.
- **SenseVoice** — best Mandarin, but no first-party Apple Silicon path (community
  ports only). Revisit only if Chinese becomes a hard requirement.
- **Moonshine** — English-only; speed edge disappears on long meeting audio.

## Risks / unknowns to resolve in the spike

1. **Benchmarks are high-end / batch.** 155–190× are M4 Pro / batch figures; a
   16 GB base Mac single-stream will be slower (still > realtime). Re-benchmark on
   a real target Mac.
2. **Mandarin unmeasured.** Keeping WhisperKit large-v3-turbo as fallback preserves
   the proven Chinese path; route by detected language or expose as a setting.
3. **Meeting audio ≠ benchmark audio.** Noisy, multi-speaker, distant-mic meetings
   will be worse than clean read-speech / earnings WERs for every engine.
4. **Pipeline integration (load-bearing):** confirm Parakeet/FluidAudio returns
   **per-segment timestamps** and works on the **separate mic vs. system audio
   files** — both required by `SpeakerFuser` and the "Me vs. remote" split. Verify
   FluidAudio's **minimum macOS** (sources cite 13+/14+, unconfirmed) against the
   macOS 14 target.

## Spike plan (next step)

A low-risk, reversible experiment on this branch:

1. Add FluidAudio as an SPM dependency (in MeetingKit, alongside WhisperKit, under
   `#if canImport(FluidAudio)`).
2. Implement `FluidAudioTranscriber: Transcribing` (actor) mirroring
   `WhisperKitTranscriber`: `prepare`, `setConcurrentWorkers` (no-op if N/A),
   `transcribe(audioFile:channel:progress:) -> [TranscriptSegment]` mapping
   FluidAudio segments → `TranscriptSegment` with start/end/text/channel.
3. Route it through `Backends.makeTranscriber(...)` behind a hidden setting /
   build flag so it doesn't disturb the default path.
4. Benchmark harness: run both engines on a few real recordings (English + at least
   one Mandarin), measuring wall-clock RTFx and eyeballing accuracy + that
   timestamps and the mic/system split survive intact.
5. Decide: if Parakeet holds up, make it the default and keep WhisperKit as the
   Mandarin/fallback engine; update `CLAUDE.md` + `REQUIREMENTS.md` (R5 is
   multilingual — keep that true via the fallback).

## Spike results (measured 2026-06-17)

Run with `TranscribeBench` on real recordings. **Machine:** Apple M1 Pro, 32 GB,
macOS 26.5.1. Parakeet = `.v2` (English) via FluidAudio 0.15.3 (ANE); WhisperKit =
large-v3-turbo. RTFx = audio-seconds ÷ wall-seconds (higher is faster).

| Clip | Engine | Wall | RTFx | Segments | Notes |
|---|---|---|---|---|---|
| 159 s **mic** (dense English speech) | WhisperKit | 113.07 s | **1.4×** | 67 | barely real-time once there's real speech |
| 159 s **mic** (same) | Parakeet | **1.07 s** | **149.3×** | 54 | ~**105× faster wall-clock** |
| 118 s system (near-silent) | WhisperKit | 16.78 s | 7.0× | 0 | empty (no remote speech) |
| 118 s system (near-silent) | Parakeet | 0.63 s | 187.8× | 0 | empty |
| 159 s system (near-silent) | WhisperKit | 19.14 s | 8.3× | 1 | only a "Thank you." hallucination |
| 159 s system (near-silent) | Parakeet | 0.90 s | 176.3× | 0 | empty |

**Speed — decisive.** On the only clip with real dense speech, WhisperKit dropped
to **1.4× RTFx** (113 s for 159 s of audio) while Parakeet held **~149×** (1.07 s)
— about **100× faster** wall-clock. The advantage is largest exactly where it
matters (long meetings with lots of talking).

**Accuracy — comparable on this clip.** Both captured the gist. WhisperKit was
marginally more faithful (e.g. "That's game day" vs Parakeet "That's game game";
Parakeet hallucinated "in the crumble"); Parakeet had cleaner punctuation/casing.
Neither was clearly better on fast, casual, overlapping speech. Mandarin was not
exercised (no Mandarin clip on hand) — WhisperKit fallback remains the safe path
there.

**Caveats from the run.** (1) A CoreML `E5RT … zero shape` warning is logged on
near-silent audio (emitted during the WhisperKit/CoreML run on macOS 26); it did
not crash and output was still produced. (2) Parakeet returns empty on silent
audio (no false "Thank you." hallucination — arguably better). (3) These are
single-stream numbers on an M1 Pro; a 16 GB base Mac will be somewhat slower but
the order-of-magnitude gap holds.

**Conclusion:** the spike confirms the recommendation. Parakeet is dramatically
faster with comparable English accuracy. Proposed next step: keep WhisperKit the
default for now (Mandarin safety), ship the engine picker so Parakeet is opt-in,
and consider making Parakeet the default after a Mandarin check and a wider
accuracy pass on noisier meeting audio.

## Key sources

- FluidAudio: <https://github.com/FluidInference/FluidAudio> ·
  [benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- Parakeet-TDT-0.6B-v2 model card: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2>
- FluidAudio CoreML build: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml>
- arXiv 2510.06961: <https://arxiv.org/html/2510.06961v4>
- Apple WWDC25 session 277 (SpeechAnalyzer): <https://developer.apple.com/videos/play/wwdc2025/277/>
