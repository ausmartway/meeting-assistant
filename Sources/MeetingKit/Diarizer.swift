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

/// The result of diarizing one audio file: per-speaker time spans plus the
/// centroid voiceprint of each cluster (for matching against the speaker library).
public struct DiarizationOutcome: Sendable, Equatable {
    public let spans: [DiarizedSpan]            // speakerID = raw cluster id
    public let embeddings: [String: [Float]]    // cluster id → centroid voiceprint
    public init(spans: [DiarizedSpan], embeddings: [String: [Float]]) {
        self.spans = spans
        self.embeddings = embeddings
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
    /// Intentionally reuses `TranscribeProgressHandler` so diarization plugs into
    /// the app's existing `(fraction, phase)` progress plumbing without conversions.
    func prepare(progress: TranscribeProgressHandler?) async throws

    /// Diarize one audio file into speaker spans (with raw cluster ids) plus the
    /// per-cluster centroid voiceprints, for matching against the speaker library.
    func diarize(
        audioFile: URL,
        progress: TranscribeProgressHandler?
    ) async throws -> DiarizationOutcome
}

/// No-ML placeholder. Returns no spans, so the fuser keeps today's mic = "Me".
public struct StubDiarizer: Diarizing {
    public init() {}
    public func prepare(progress: TranscribeProgressHandler?) async throws {}
    public func diarize(
        audioFile: URL,
        progress: TranscribeProgressHandler?
    ) async throws -> DiarizationOutcome {
        DiarizationOutcome(spans: [], embeddings: [:])
    }
}

// MARK: - Real engine (compiled only when FluidAudio is available)

#if canImport(FluidAudio)
import FluidAudio

/// On-device diarization via FluidAudio's offline VBx pipeline. An actor so the
/// CoreML models download/load exactly once even under concurrent calls
/// (mirrors `WhisperKitTranscriber`).
///
/// API shape (FluidAudio 0.15.x): `OfflineDiarizerManager` is a *pure
/// unsupervised* batch pipeline. It clusters a file into anonymous speakers
/// ("1", "2", …) and returns, per speaker, a centroid embedding in
/// `DiarizationResult.speakerDatabase`. We surface both the spans (with their raw
/// cluster ids) and those centroid voiceprints as a `DiarizationOutcome`; matching
/// clusters to known people happens later, in a separate pure recognizer.
public actor FluidAudioDiarizer: Diarizing {
    // Memoize the *task*, not the result, so concurrent callers share one
    // download/compile (same reentrancy reasoning as WhisperKitTranscriber).
    private var loadTask: Task<OfflineDiarizerManager, Error>?

    public init() {}

    /// App-owned model location, alongside the Whisper models, so downloads land
    /// in our Application Support folder rather than FluidAudio's default cache.
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
        progress: TranscribeProgressHandler?
    ) async throws -> DiarizationOutcome {
        let mgr = try await manager(progress: progress)
        progress?(TranscribeProgress(fraction: 0, phase: "Separating in-room speakers…"))
        let result = try await mgr.process(audioFile)
        let spans = result.segments.map {
            DiarizedSpan(start: TimeInterval($0.startTimeSeconds),
                         end: TimeInterval($0.endTimeSeconds),
                         speakerID: $0.speakerId)
        }
        return DiarizationOutcome(spans: spans, embeddings: result.speakerDatabase ?? [:])
    }

    /// The centroid embedding of the speaker who talks the most in a result —
    /// the enrolled user, for a solo enrollment clip.
    private static func dominantSpeakerEmbedding(_ result: DiarizationResult) -> [Float]? {
        guard let db = result.speakerDatabase, !db.isEmpty else { return nil }
        // Sum span durations per speaker to find the most-talkative one.
        var durationByID: [String: Double] = [:]
        for seg in result.segments {
            durationByID[seg.speakerId, default: 0] +=
                Double(seg.endTimeSeconds - seg.startTimeSeconds)
        }
        let dominantID = durationByID.max(by: { $0.value < $1.value })?.key
            ?? db.keys.first
        guard let dominantID, let embedding = db[dominantID] else { return nil }
        return embedding
    }

    /// Download (once) and load the offline diarization models. Reentrancy-safe
    /// via task memoization, with the failed task cleared so a later attempt
    /// (e.g. Re-process) can retry.
    private func manager(progress: TranscribeProgressHandler?) async throws -> OfflineDiarizerManager {
        if let loadTask { return try await loadTask.value }
        let task = Task { () throws -> OfflineDiarizerManager in
            progress?(TranscribeProgress(fraction: nil, phase: "Loading diarization model…"))
            let mgr = OfflineDiarizerManager()
            // prepareModels downloads + compiles the CoreML bundles when missing,
            // into our app-owned directory.
            try await mgr.prepareModels(directory: Self.modelDir)
            return mgr
        }
        loadTask = task
        do { return try await task.value }
        catch { loadTask = nil; throw error }
    }
}
#endif
