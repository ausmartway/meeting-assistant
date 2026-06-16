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

    /// Diarize one audio file into speaker spans. When `enrollment` is provided,
    /// spans matching the enrolled user carry `speakerID == "Me"`.
    func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan]
}

/// No-ML placeholder. Returns no spans, so the fuser keeps today's mic = "Me".
public struct StubDiarizer: Diarizing {
    public init() {}
    public func prepare(progress: TranscribeProgressHandler?) async throws {}
    public func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,        // ignored: the stub does no speaker matching
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan] { [] }
}

// MARK: - Real engine (compiled only when FluidAudio is available)

#if canImport(FluidAudio)
import FluidAudio

/// On-device diarization via FluidAudio's offline VBx pipeline. An actor so the
/// CoreML models download/load exactly once even under concurrent calls
/// (mirrors `WhisperKitTranscriber`).
///
/// API shape (FluidAudio 0.15.x) differs from a naive "enrollSpeaker" guess:
/// `OfflineDiarizerManager` is a *pure unsupervised* batch pipeline. It has no
/// speaker-enrollment entry point — it clusters a file into anonymous speakers
/// ("1", "2", …) and returns, per speaker, a centroid embedding in
/// `DiarizationResult.speakerDatabase`. We therefore implement "Me" matching
/// ourselves: diarize the short enrollment clip, take its dominant speaker's
/// embedding, then rename whichever meeting speaker's centroid is closest (within
/// a cosine-distance threshold) to `DiarizationLabeler.meSpeakerID`.
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

    /// Max cosine distance for an enrolled-user embedding to be accepted as a
    /// match for a meeting speaker. FluidAudio's own `SpeakerManager` defaults to
    /// 0.65 for online assignment; we use the same value as a sane starting point.
    /// If no speaker is within this distance, no span is labeled "Me" and the
    /// fuser degrades to anonymous speakers.
    private static let meMatchThreshold: Float = 0.65

    public func prepare(progress: TranscribeProgressHandler?) async throws {
        _ = try await manager(progress: progress)
    }

    public func diarize(
        audioFile: URL,
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan] {
        let mgr = try await manager(progress: progress)
        progress?(TranscribeProgress(fraction: 0, phase: "Separating in-room speakers…"))

        // Diarize the meeting. `process(_:)` memory-maps the file and resamples to
        // the model's rate internally, so we don't decode/convert ourselves.
        let result = try await mgr.process(audioFile)

        // Optionally figure out which anonymous speaker is the enrolled user.
        // Matching is best-effort: a silent/unreadable enrollment clip must NOT
        // discard the already-computed in-room separation, so `try?` collapses any
        // failure (or no confident match) into "nobody labeled Me".
        var meSpeakerID: String? = nil
        if let enrollment {
            progress?(TranscribeProgress(fraction: nil, phase: "Matching your voice…"))
            meSpeakerID = try? await matchEnrolledSpeaker(
                manager: mgr,
                enrollment: enrollment,
                meetingSpeakers: result.speakerDatabase
            )
        }

        // FluidAudio segment times are Float seconds; speakerId is the cluster id.
        return result.segments.map { seg in
            let raw = seg.speakerId
            let id = (raw == meSpeakerID) ? DiarizationLabeler.meSpeakerID : raw
            return DiarizedSpan(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speakerID: id
            )
        }
    }

    /// Diarize the enrollment clip, extract the dominant speaker's centroid
    /// embedding, and return the meeting speaker id whose centroid is closest
    /// (within `meMatchThreshold`). Returns `nil` if there's no confident match —
    /// in which case nothing is labeled "Me".
    private func matchEnrolledSpeaker(
        manager mgr: OfflineDiarizerManager,
        enrollment: MeEnrollment,
        meetingSpeakers: [String: [Float]]?
    ) async throws -> String? {
        guard let meetingSpeakers, !meetingSpeakers.isEmpty else { return nil }

        // Run the same pipeline on the short enrollment clip. It should resolve to
        // ~1 speaker; we pick the one with the most speech (the longest total span)
        // as the enrolled user's reference.
        let enrollResult = try await mgr.process(enrollment.audioFile)
        guard let enrollEmbedding = Self.dominantSpeakerEmbedding(enrollResult) else { return nil }

        var best: (id: String, distance: Float)? = nil
        for (id, embedding) in meetingSpeakers {
            guard embedding.count == enrollEmbedding.count else { continue }
            let distance = SpeakerUtilities.cosineDistance(enrollEmbedding, embedding)
            if best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        guard let best, best.distance <= Self.meMatchThreshold else { return nil }
        return best.id
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
