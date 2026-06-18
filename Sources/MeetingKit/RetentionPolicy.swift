import Foundation

/// Pure, time-based retention decisions for a meeting bundle. Two independent
/// windows: heavy audio expires first (`mediaMaxAge`); the whole bundle —
/// including the tiny transcript — is deleted only after `transcriptMaxAge`.
/// A `nil` window means "never" for that action. Injecting `now` keeps every
/// decision deterministic and unit-testable.
public struct RetentionPolicy: Equatable, Sendable {
    public var mediaMaxAge: TimeInterval?       // nil = never expire audio
    public var transcriptMaxAge: TimeInterval?  // nil = keep the bundle forever

    public init(mediaMaxAge: TimeInterval?, transcriptMaxAge: TimeInterval?) {
        self.mediaMaxAge = mediaMaxAge
        self.transcriptMaxAge = transcriptMaxAge
    }

    /// Defaults: audio 7 days, transcript 1 year.
    public static let `default` = RetentionPolicy(
        mediaMaxAge: 7 * 86_400,
        transcriptMaxAge: 365 * 86_400
    )

    /// True when the recording's audio is older than the media window.
    public func shouldExpireMedia(recordedAt: Date, now: Date) -> Bool {
        guard let mediaMaxAge else { return false }
        return now.timeIntervalSince(recordedAt) > mediaMaxAge
    }

    /// True when the entire bundle is older than the transcript window.
    public func shouldDeleteBundle(recordedAt: Date, now: Date) -> Bool {
        guard let transcriptMaxAge else { return false }
        return now.timeIntervalSince(recordedAt) > transcriptMaxAge
    }
}

/// What a single retention sweep reclaimed — for logging and the "Clean up now"
/// summary.
public struct RetentionSweepResult: Equatable, Sendable {
    public var bundlesDeleted: Int
    public var mediaExpired: Int
    public var bytesReclaimed: Int64

    public init(bundlesDeleted: Int = 0, mediaExpired: Int = 0, bytesReclaimed: Int64 = 0) {
        self.bundlesDeleted = bundlesDeleted
        self.mediaExpired = mediaExpired
        self.bytesReclaimed = bytesReclaimed
    }
}
