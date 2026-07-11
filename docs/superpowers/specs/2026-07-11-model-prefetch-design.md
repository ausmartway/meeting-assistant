# Background model prefetch after mandatory permissions

**Date:** 2026-07-11
**Status:** Approved

## Problem

Today the heavy transcription models download lazily at the first transcription
that needs them (Parakeet on the first English channel, the big Whisper model on
the first Mandarin/uncertain channel). From the end-user's point of view the
first meeting pays a surprise multi-hundred-MB download at processing time.
Meanwhile the small language-detector model downloads at app launch regardless
of permission state — before the app is even usable.

## Goal

Download **all** transcription models in the background, non-blocking, starting
the moment the app has all mandatory permissions (Screen & Audio Recording,
Microphone, Calendar). Loading/compiling stays lazy — downloading is separable
from the documented model-compile hazard (multi-minute ANE compile; GPU-path
abort on macOS 26, see `Transcriber.swift` compute-options comment).

## Decisions (user-confirmed)

1. **Prefetch depth: download only.** Fetch model files to disk; never load or
   compile ahead of time. First use still pays the one-time load/ANE compile.
2. **Trigger: all three mandatory permissions granted.** Checked at launch (for
   already-set-up users) and on every permission refresh during onboarding.
   Until then, *no* model downloads at all — including the small detector,
   which today downloads at launch unconditionally.
3. **UI: subtle status.** A quiet progress line reuses the existing
   `modelStatusText` / `modelDownloadFraction` plumbing ("Downloading models…
   42%"). Nothing blocks; recording and processing work regardless. Failures
   are non-fatal and quiet — the lazy download-on-first-use path remains as the
   fallback and natural retry.

## Design (Approach A)

### 1. `Transcribing.prefetch(progress:)` — new optional protocol method

Default implementation: no-op. Implementations:

- **`WhisperKitTranscriber.prefetch`** — runs only the download half of the
  existing `buildPipeline`: `isModelComplete(at:)` short-circuit, else
  `WhisperKit.download` with the existing wipe-and-retry-once semantics.
  No `WhisperKit(…)` init, so nothing loads or compiles.
- **`FluidAudioTranscriber.prefetch`** — calls FluidAudio's download-only
  `AsrModels.download(version:)` (exists upstream; `downloadAndLoad` stays for
  the real transcription path).
- **`AutoRoutingTranscriber.prefetch`** — sequential (bandwidth-friendly):
  1. `prepare` the small detector (download **and** load — it is cheap, always
     needed for routing, and today's `prepare` already does this),
  2. `parakeet.prefetch` (covers the common English path first),
  3. `whisper.prefetch` (the big model last).
- **`StubTranscriber.prefetch`** — records the call for tests.

### 2. `ModelPrefetchPolicy` — pure gate logic (MeetingKit)

```swift
enum ModelPrefetchPolicy {
    static func shouldStart(
        screenRecording: SetupPermissionStatus,
        microphone: SetupPermissionStatus,
        calendar: SetupPermissionStatus,
        alreadyStarted: Bool
    ) -> Bool
}
```

True iff all three are `.granted` and `alreadyStarted` is false. Trivial, but
pure and unit-tested per project convention.

### 3. `AppState` wiring

- `start()` no longer calls `prepareModel()` unconditionally. Instead a new
  `startModelPrefetchIfReady()` runs at launch and after every
  `permissions.refresh()` (onboarding polls refresh already; the 30 s `tick()`
  also calls it so a grant made outside onboarding is picked up).
- When the policy fires, one background `Task` runs the existing
  `prepareModel()` (which prepares the transcriber — for `.auto` that is the
  small detector) followed by `transcriber.prefetch(progress:)` reporting into
  the same status fields. A flag ensures it runs once per app session;
  `prepareModel()` stays independently reachable from Settings (model change,
  retry button) exactly as today.
- Processing continues to wait only on `modelReady` (set by `prepare`, as
  today), never on prefetch completion.

## Error handling

Prefetch failures set a quiet status ("Model download failed — will retry when
needed") and clear the in-progress flag for the *download* portion only; they
never surface as blocking errors. A partial download is wiped by the existing
retry logic; whatever is missing at transcription time is fetched by the
unchanged lazy path.

## Testing

- `ModelPrefetchPolicy` — swift-testing suite over the permission/started
  matrix.
- `AutoRoutingTranscriber.prefetch` — stub detector/whisper/parakeet recording
  call order; asserts detector prepared first, then parakeet, then whisper.
  Sequential fail-fast on error (the lazy path covers whatever is missing);
  a test asserts the fail-fast.
- `WhisperKitTranscriber` / `FluidAudioTranscriber` prefetch are thin wrappers
  over framework downloads — verified by running the app (project convention
  for framework integrations).

## Out of scope

- Diarizer model prefetch (still warmed via `prepareModel` when in-room
  identification is enabled, same as today).
- Notification when models are ready; metered-connection handling.
