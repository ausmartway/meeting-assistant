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
        enrollment: MeEnrollment?,
        progress: TranscribeProgressHandler?
    ) async throws -> [DiarizedSpan] { [] }
}
