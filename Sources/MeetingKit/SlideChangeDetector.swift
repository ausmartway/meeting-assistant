import Foundation

/// A tiny grey thumbnail of one captured frame — the only thing slide detection
/// needs to compare frames. 16×16 is enough to notice a slide change and small
/// enough that comparing two of them is free.
public struct FrameSignature: Equatable, Sendable {
    /// Row-major grey cells, 0–255.
    public let cells: [UInt8]

    public init(cells: [UInt8]) {
        self.cells = cells
    }

    /// Mean absolute difference from `other`, normalized to 0...1. Returns 1
    /// (maximally different) for mismatched sizes so a resized window can never
    /// look "still" by accident.
    func distance(to other: FrameSignature) -> Double {
        guard cells.count == other.cells.count, !cells.isEmpty else { return 1 }
        var total = 0
        for i in cells.indices {
            total += abs(Int(cells[i]) - Int(other.cells[i]))
        }
        return Double(total) / (Double(cells.count) * 255.0)
    }
}

/// Decides which captured frames are worth keeping as presentation keyframes,
/// from frame signatures alone — no Vision, no per-app knowledge.
///
/// The rule is **change-then-settle**: keep a frame when it is *holding still*
/// (barely differs from the previous sample) yet *new* (differs a lot from the last
/// frame we kept). Talking heads never hold still — webcam noise alone moves every
/// pixel between samples 2.5 s apart — while a slide, document, or dashboard holds
/// perfectly still. So "holds still" is what separates presented content from faces.
///
/// Deciding on the *current* frame rather than confirming the previous one means no
/// pixel buffer or encoded image is ever held between samples; the cost is that a
/// slide is stamped up to one sample interval after it appeared, which is irrelevant
/// for a slide that stays up for minutes.
///
/// What `consider` decided, plus the two distances behind the decision — logged by
/// `SlideRecorder` so the thresholds can be calibrated from real meetings without a
/// duplicate copy of the render-and-reduce pipeline.
public struct SlideDecision: Equatable, Sendable {
    public let save: Bool
    /// Distance to the previous sample. Below `stillThreshold` means "holding still".
    /// Nil for the very first sample, which has no predecessor.
    public let stillDistance: Double?
    /// Distance to the last kept keyframe. Above `changeThreshold` means "new
    /// content". Nil when no keyframe has been kept yet.
    public let changeDistance: Double?
}

/// Pure and deterministic (no I/O, no frameworks), so every branch is unit-tested.
public struct SlideChangeDetector {
    /// Distance below which consecutive samples count as "the picture is holding
    /// still". Calibrated against real meetings — see the plan's Task 1.
    public var stillThreshold: Double
    /// Distance above which a still frame counts as genuinely new content rather
    /// than the keyframe we already kept.
    public var changeThreshold: Double
    /// Floor between saved keyframes, so a flickering share can't burst.
    public var minInterval: TimeInterval
    /// Hard per-meeting cap, bounding worst-case disk use.
    public var maxKeyframes: Int

    private var previous: FrameSignature?
    private var lastKeyframe: FrameSignature?
    private var lastKeyframeTime: TimeInterval?
    private var count = 0

    public init(
        stillThreshold: Double = 0.02,
        changeThreshold: Double = 0.10,
        minInterval: TimeInterval = 5,
        maxKeyframes: Int = 300
    ) {
        self.stillThreshold = stillThreshold
        self.changeThreshold = changeThreshold
        self.minInterval = minInterval
        self.maxKeyframes = maxKeyframes
    }

    /// Whether the per-meeting cap has been reached — further frames will never be
    /// saved. Lets a caller skip the (comparatively expensive) render step entirely
    /// once nothing it produces could be kept.
    public var isExhausted: Bool { count >= maxKeyframes }

    /// Whether the caller should save `signature`'s frame as a keyframe.
    /// Call once per sampled frame, in time order.
    public mutating func consider(_ signature: FrameSignature, at t: TimeInterval) -> Bool {
        decide(signature, at: t).save
    }

    /// Same decision as `consider`, plus the two distances it was based on — so a
    /// caller can log real numbers for threshold calibration instead of
    /// re-implementing this comparison. Call once per sampled frame, in time order.
    public mutating func decide(_ signature: FrameSignature, at t: TimeInterval) -> SlideDecision {
        defer { previous = signature }

        let stillDistance = previous.map { signature.distance(to: $0) }
        let changeDistance = lastKeyframe.map { signature.distance(to: $0) }
        func result(_ save: Bool) -> SlideDecision {
            SlideDecision(save: save, stillDistance: stillDistance, changeDistance: changeDistance)
        }

        // No predecessor yet: we can't know the picture is still, and second-zero
        // content is as likely to be a lobby screen as a slide.
        guard let stillDistance else { return result(false) }
        guard count < maxKeyframes else { return result(false) }
        guard stillDistance <= stillThreshold else { return result(false) }

        if let lastKeyframeTime, t - lastKeyframeTime < minInterval { return result(false) }
        if let changeDistance, changeDistance < changeThreshold {
            return result(false)
        }

        lastKeyframe = signature
        lastKeyframeTime = t
        count += 1
        return result(true)
    }
}
