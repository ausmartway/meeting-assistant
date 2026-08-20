import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO  // kCGImageDestinationLossyCompressionQuality
import os

/// Saves pictures of a shared screen during a meeting: reduces each sampled frame to
/// a `FrameSignature`, asks `SlideChangeDetector` whether it is a new slide, and writes
/// a JPEG when it is.
///
/// An `actor` for two reasons. First, the detector's rule depends on frames arriving in
/// **time order**; actor isolation only gives mutual exclusion between `consider` calls,
/// not ordering — each call arrives from its own `Task` after a Vision OCR of variable
/// latency (see `CaptureSession.handleVideoFrame`), so a slow OCR can let a later
/// frame's `Task` reach us first. `consider` below defends the ordering itself, by
/// dropping any frame whose timestamp doesn't strictly advance.
/// Second — and this is the load-bearing one — `CaptureSession`'s `outputQueue` is a
/// *serial* queue shared by the system-audio and screen-frame handlers, so CoreImage and
/// file work must never run on it: ScreenCaptureKit sheds samples when a client's handler
/// queue backs up, and because `system.wav` is written by appending buffers with no
/// timestamps, shed samples silently shorten the file and shift every later word earlier.
/// Calls therefore arrive from the `Task` that `handleVideoFrame` already spawns.
///
/// Best-effort throughout (N3): an unreadable frame or a failed write is logged and
/// dropped. Nothing here can fail a recording.
public actor SlideRecorder {
    /// Cells per side of the grey signature (16×16 = 256 cells).
    private static let signatureSide = 16
    private static let log = Logger(subsystem: "MeetingAssistant", category: "slides")

    private let bundleDirectory: URL
    private let fileManager: FileManager
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var detector: SlideChangeDetector
    private var saved: [SlideKeyframe] = []
    private var didCreateDirectory = false
    private var lastConsideredTime: TimeInterval?

    public init(
        directory: URL,
        detector: SlideChangeDetector = .init(),
        fileManager: FileManager = .default
    ) {
        self.bundleDirectory = directory
        self.detector = detector
        self.fileManager = fileManager
    }

    /// Consider one sampled frame; writes a keyframe if it looks like new, settled
    /// presentation content. Call in time order, once per sampled frame.
    public func consider(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        // Defense-in-depth for SlideChangeDetector's "call in time order" precondition:
        // the call site awaits a variable-latency Vision OCR before reaching us (see the
        // type's doc comment above), so an earlier frame's Task can be overtaken by a
        // later one's. This is expected under load, not an error — drop and move on.
        if let lastConsideredTime, t <= lastConsideredTime {
            Self.log.info(
                "Dropping an out-of-order frame at \(t, privacy: .public)s (last considered was \(lastConsideredTime, privacy: .public)s)."
            )
            return
        }
        lastConsideredTime = t

        // The cap is hit rarely (a very long meeting), but once it is, every
        // remaining sample would otherwise pay for a CoreImage render it can never
        // keep — skip it before doing any of that work.
        guard !detector.isExhausted else { return }

        guard let signature = signature(of: pixelBuffer) else { return }
        let decision = detector.decide(signature, at: t)
        Self.log.info(
            "SLIDEDIST t=\(Int(t), privacy: .public) still=\(Self.format(decision.stillDistance), privacy: .public) change=\(Self.format(decision.changeDistance), privacy: .public) save=\(decision.save ? 1 : 0, privacy: .public)"
        )
        guard decision.save else { return }
        write(pixelBuffer, at: t)
    }

    /// Format an optional distance to 4 decimal places for the greppable
    /// `SLIDEDIST` log line — calibration tooling parses this text.
    private static func format(_ distance: Double?) -> String {
        guard let distance else { return "nil" }
        return String(format: "%.4f", distance)
    }

    /// Every keyframe written so far, oldest first. Read once at `stop()`.
    public func keyframes() -> [SlideKeyframe] {
        saved
    }

    // MARK: - Signature

    /// Downscale the frame to a 16×16 grey thumbnail. One small GPU render per sampled
    /// frame — the whole cost of slide detection.
    private func signature(of pixelBuffer: CVPixelBuffer) -> FrameSignature? {
        let side = Self.signatureSide
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let scaled = image.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(side) / image.extent.width,
                y: CGFloat(side) / image.extent.height))

        var bitmap = [UInt8](repeating: 0, count: side * side * 4)
        context.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: side * 4,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())

        // Rec. 601 luma: cheap, and matches how "brightness changed" reads to a viewer.
        var cells = [UInt8](repeating: 0, count: side * side)
        for i in 0..<(side * side) {
            let r = Int(bitmap[i * 4])
            let g = Int(bitmap[i * 4 + 1])
            let b = Int(bitmap[i * 4 + 2])
            cells[i] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
        }
        return FrameSignature(cells: cells)
    }

    // MARK: - Writing

    /// Encode the frame as JPEG and append it to the manifest. Named by whole-second
    /// offset, so filenames are deterministic and sort chronologically; the 5 s
    /// `minInterval` makes collisions impossible.
    private func write(_ pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        let name = String(format: "slide-%05d.jpg", Int(t))
        let relativePath = "slides/\(name)"
        let directory = bundleDirectory.appendingPathComponent("slides", isDirectory: true)

        if !didCreateDirectory {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                didCreateDirectory = true
            } catch {
                Self.log.error(
                    "Couldn't create the slides directory: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard
            let data = context.jpegRepresentation(
                of: image,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                options: [
                    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7
                ]
            )
        else {
            Self.log.error("Couldn't encode a slide keyframe as JPEG.")
            return
        }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            saved.append(SlideKeyframe(timestamp: t, file: relativePath))
        } catch {
            Self.log.error(
                "Couldn't write \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
