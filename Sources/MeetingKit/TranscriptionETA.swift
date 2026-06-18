import Foundation

/// Turns a stream of transcription progress observations into a smoothed,
/// human-friendly "time remaining" label. Pure and deterministic: the caller
/// supplies `elapsed` (wall-time since transcription started) and the live
/// `fraction` (0...1), so there are no timers or clocks inside — which makes the
/// smoothing and rounding fully unit-testable.
///
/// Design (see spec N10):
///  • remaining ≈ elapsed × (1 − f) / f
///  • a gate (minFraction / minElapsed) suppresses the wild early estimates
///  • the smoothed value falls freely but rises only gently, so channel-
///    interleaving noise can't make the countdown jump upward.
public struct TranscriptionETA {
    private let minFraction: Double
    private let minElapsed: TimeInterval
    private let smoothing: Double
    private var smoothedRemaining: TimeInterval?

    public init(minFraction: Double = 0.03, minElapsed: TimeInterval = 3, smoothing: Double = 0.3) {
        self.minFraction = minFraction
        self.minElapsed = minElapsed
        self.smoothing = smoothing
    }

    /// Clear all state between meetings.
    public mutating func reset() { smoothedRemaining = nil }

    /// Feed one progress observation; returns the current friendly label, or nil
    /// if no stable estimate is available yet.
    public mutating func update(elapsed: TimeInterval, fraction: Double) -> String? {
        // Below the gates (too early, or not enough progress, or already complete):
        // don't compute a new estimate, but keep showing the last stable one if any.
        guard fraction >= minFraction, fraction < 1, elapsed >= minElapsed else {
            return smoothedRemaining.map(Self.label(for:))
        }
        let raw = elapsed * (1 - fraction) / fraction
        if let prev = smoothedRemaining {
            // Fall freely; rise gently (EMA toward the higher raw value).
            smoothedRemaining = raw < prev ? raw : prev + smoothing * (raw - prev)
        } else {
            smoothedRemaining = raw
        }
        return smoothedRemaining.map(Self.label(for:))
    }

    /// Map a remaining-seconds value to a rough, friendly label.
    public static func label(for seconds: TimeInterval) -> String {
        if seconds >= 90 {
            let mins = Int((seconds / 60).rounded())
            return "~\(mins) min left"
        } else if seconds >= 45 {
            return "~1 min left"
        } else if seconds >= 20 {
            return "under a minute"
        } else {
            return "almost done"
        }
    }
}
