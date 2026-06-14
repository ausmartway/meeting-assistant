import Foundation

/// Whisper model size. All entries are **multilingual** (no `.en` variants) so
/// the recognizer can handle Mandarin as well as English with language
/// auto-detection. Larger = more accurate but slower / more memory.
/// Defaults to `.largeTurbo` — strong Mandarin accuracy, still fast on the M1
/// Pro's Neural Engine.
public enum TranscriptionModel: String, Codable, Sendable, CaseIterable {
    case small = "small"
    case medium = "medium"
    // WhisperKit/HuggingFace folder is "openai_whisper-large-v3_turbo" — the
    // turbo suffix uses an underscore, not a hyphen (a hyphen → modelsUnavailable).
    case largeTurbo = "large-v3_turbo"

    public var displayName: String {
        switch self {
        case .small: return "Small (fastest, ~0.5 GB)"
        case .medium: return "Medium (balanced, ~1.5 GB)"
        case .largeTurbo: return "Large v3 Turbo (best, multilingual, ~1.6 GB)"
        }
    }

    /// Approximate on-disk download size, shown in progress UI before a download.
    public var approxDownloadDescription: String {
        switch self {
        case .small: return "~0.5 GB"
        case .medium: return "~1.5 GB"
        case .largeTurbo: return "~1.6 GB"
        }
    }
}

/// Coarse progress for the transcription stage. `fraction` is the model-download
/// progress (0...1) while downloading, then nil once the model is loading/running
/// (which WhisperKit doesn't surface a fraction for). `phase` is a UI label.
public struct TranscribeProgress: Sendable {
    public let fraction: Double?
    public let phase: String
    public init(fraction: Double?, phase: String) {
        self.fraction = fraction
        self.phase = phase
    }
}

public typealias TranscribeProgressHandler = @Sendable (TranscribeProgress) -> Void

/// Turns a recorded audio file into timestamped transcript segments.
///
/// This is the seam between the app and the local speech-to-text engine. The real
/// engine (WhisperKit, on the Apple Neural Engine) requires the full Xcode
/// toolchain to build; `StubTranscriber` keeps the pipeline runnable without it.
public protocol Transcribing: Sendable {
    /// Download + load the model ahead of time (e.g. at app launch) so the first
    /// transcription doesn't pay for it. Idempotent and safe to call repeatedly.
    func prepare(progress: TranscribeProgressHandler?) async throws

    /// Transcribe one audio file. `channel` is carried onto every segment so the
    /// speaker fuser can tell mic ("Me") from system (remote) audio. `progress`
    /// receives model-download / stage updates for the UI.
    func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment]
}

public extension Transcribing {
    /// Convenience overload without progress reporting.
    func transcribe(audioFile: URL, channel: AudioChannel) async throws -> [TranscriptSegment] {
        try await transcribe(audioFile: audioFile, channel: channel, progress: nil)
    }
}

/// A no-ML placeholder so the end-to-end pipeline produces visible output before
/// WhisperKit is wired in.
public struct StubTranscriber: Transcribing {
    public init() {}

    public func prepare(progress: TranscribeProgressHandler?) async throws {}

    public func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        let note = "[transcription backend not configured — open in Xcode and add WhisperKit to enable on-device speech-to-text]"
        return [TranscriptSegment(start: 0, end: 0, text: note, channel: channel)]
    }
}

// MARK: - Real engine (compiled only when WhisperKit is available)

#if canImport(WhisperKit)
import WhisperKit
import CoreML

/// An actor so the model is downloaded and loaded exactly once even when the two
/// audio channels are transcribed concurrently — concurrent downloads of the same
/// model into the same folder were corrupting it. Channel transcriptions then run
/// serially through the actor, which is also the safe way to reuse one pipeline.
public actor WhisperKitTranscriber: Transcribing {
    private let model: TranscriptionModel
    // Memoize the *task*, not the result. Storing the in-flight task and awaiting
    // it from every caller guarantees the model is downloaded/loaded exactly once
    // even under actor reentrancy (two channels both hitting an `await` before the
    // pipeline exists would otherwise each start their own download).
    private var loadTask: Task<WhisperKit, Error>?

    public init(model: TranscriptionModel = .largeTurbo) {
        self.model = model
    }

    /// App-owned location for downloaded Whisper models, instead of the
    /// swift-transformers default under ~/Documents/huggingface.
    public static var modelDownloadBase: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingAssistant/WhisperModels", isDirectory: true)
    }

    /// Directory holding all downloaded WhisperKit models (cleared on a broken
    /// download so a retry starts clean).
    private static var repoCacheDir: URL {
        modelDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    public func prepare(progress: TranscribeProgressHandler?) async throws {
        _ = try await pipeline(progress: progress)
    }

    public func transcribe(
        audioFile: URL,
        channel: AudioChannel,
        progress: TranscribeProgressHandler?
    ) async throws -> [TranscriptSegment] {
        let pipe = try await pipeline(progress: progress)
        let label = channel == .microphone ? "Transcribing your audio…" : "Transcribing others' audio…"
        progress?(TranscribeProgress(fraction: 0, phase: label))

        // Load the audio so we know its total duration — that lets us report a
        // real progress fraction (latest transcribed second / total seconds).
        let samples = try await Self.loadSamples(audioFile)
        let total = max(1.0, Double(samples.count) / 16_000.0)
        let reporter = SegmentProgressReporter(total: total, phase: label, handler: progress)

        // language: nil + detectLanguage: true → auto-detect per meeting.
        // VAD chunking processes long audio in voice-activity segments with a
        // bounded worker count, so a multi-hour meeting transcribes with flat
        // memory instead of holding everything at once (works on 16 GB).
        let options = DecodingOptions(
            language: nil,
            detectLanguage: true,
            concurrentWorkerCount: 2,
            chunkingStrategy: .vad
        )
        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options,
            segmentCallback: { segs in reporter.update(segs) }
        )
        let raw = results.flatMap { result in
            result.segments.map {
                TranscriptSegment(
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    // Strip WhisperKit's <|...|> special/timestamp tokens.
                    text: WhisperTextCleaner.clean($0.text),
                    channel: channel
                )
            }
        }
        return HallucinationFilter.clean(raw)
    }

    /// Load an audio file as 16 kHz mono float samples (resampled by WhisperKit).
    private static func loadSamples(_ url: URL) async throws -> [Float] {
        let results = await AudioProcessor.loadAudio(at: [url.path])
        guard let first = results.first else { return [] }
        return try first.get()
    }

    /// Download (once, with progress + one clean retry) and load the model.
    /// Reentrancy-safe via task memoization.
    private func pipeline(progress: TranscribeProgressHandler?) async throws -> WhisperKit {
        if let loadTask { return try await loadTask.value }
        let task = Task { try await self.buildPipeline(progress: progress) }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil   // allow a later attempt (e.g. Re-process) to retry
            throw error
        }
    }

    private func buildPipeline(progress: TranscribeProgressHandler?) async throws -> WhisperKit {
        // Expected on-disk folder for this model.
        let localFolder = Self.repoCacheDir.appendingPathComponent("openai_whisper-\(model.rawValue)")
        let alreadyDownloaded = Self.isModelComplete(at: localFolder)

        let folder: URL
        if alreadyDownloaded {
            // Cached from a previous run — DON'T re-download or re-verify over the
            // network. Just load it. (This is the fix for "downloads every launch".)
            folder = localFolder
        } else {
            let downloadLabel = "Downloading model (\(model.approxDownloadDescription))…"
            let report: ProgressCallback = { p in
                progress?(TranscribeProgress(fraction: p.fractionCompleted, phase: downloadLabel))
            }
            progress?(TranscribeProgress(fraction: 0, phase: downloadLabel))
            do {
                folder = try await download(report)
            } catch {
                // A partial/corrupt download can't be resumed cleanly — wipe and retry.
                try? FileManager.default.removeItem(at: Self.repoCacheDir)
                progress?(TranscribeProgress(fraction: 0, phase: "Retrying download…"))
                folder = try await download(report)
            }
        }

        progress?(TranscribeProgress(fraction: nil, phase: "Loading model…"))
        // Run the encoder + decoder on the GPU instead of the Apple Neural Engine.
        // WhisperKit defaults to .cpuAndNeuralEngine, whose FIRST-time ANE compile
        // of a large model takes many minutes (ANECompilerService pinned at ~100%,
        // app blocked — looks hung). GPU avoids that compile and loads quickly; for
        // batch post-meeting processing the throughput difference is negligible.
        let compute = ModelComputeOptions(
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU
        )
        // When cached, load fully offline (download:false) so nothing hits the
        // network — the tokenizer is already on disk too. On a first run we need
        // download:true so WhisperKit can fetch the tokenizer (a separate repo).
        func makeConfig(allowDownload: Bool) -> WhisperKitConfig {
            WhisperKitConfig(
                downloadBase: Self.modelDownloadBase,
                modelFolder: folder.path,
                computeOptions: compute,
                download: allowDownload
            )
        }
        do {
            return try await WhisperKit(makeConfig(allowDownload: !alreadyDownloaded))
        } catch where alreadyDownloaded {
            // Offline load failed (e.g. tokenizer missing) — allow a fetch and retry.
            return try await WhisperKit(makeConfig(allowDownload: true))
        }
    }

    /// True when the model folder has the core CoreML components on disk.
    private static func isModelComplete(at folder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return false }
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        return required.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    private func download(_ progress: @escaping ProgressCallback) async throws -> URL {
        try await WhisperKit.download(
            variant: model.rawValue,
            downloadBase: Self.modelDownloadBase,
            progressCallback: progress
        )
    }
}

/// Turns WhisperKit's segment-discovery callbacks into a 0...1 progress fraction
/// (latest transcribed second / total seconds). Lock-guarded because WhisperKit
/// invokes the callback from its own threads.
private final class SegmentProgressReporter: @unchecked Sendable {
    private let total: Double
    private let phase: String
    private let handler: TranscribeProgressHandler?
    private let lock = NSLock()
    private var maxEnd: Double = 0

    init(total: Double, phase: String, handler: TranscribeProgressHandler?) {
        self.total = total
        self.phase = phase
        self.handler = handler
    }

    func update(_ segments: [TranscriptionSegment]) {
        lock.lock()
        for s in segments where Double(s.end) > maxEnd { maxEnd = Double(s.end) }
        let fraction = min(1.0, maxEnd / total)
        lock.unlock()
        handler?(TranscribeProgress(fraction: fraction, phase: phase))
    }
}
#endif
