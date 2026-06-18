import Foundation
import CoreImage
import Vision

/// Best-effort reader of "who is speaking now" from a single captured video frame.
///
/// Approach: find the participant tiles, score each tile's border for the bright,
/// saturated ring meeting apps draw around the active speaker, then OCR the name
/// label inside the most-highlighted tile.
///
/// This is the deliberately fragile part of the system (see the design's risk
/// notes): highlight colors and layouts vary by app, version, theme, and gallery
/// vs. speaker view. It returns `speakerName: nil` whenever it can't confidently
/// read a name, and the `SpeakerFuser` degrades gracefully to "Speaker" in that
/// case. The mic-vs-system split remains the reliable speaker signal.
public final class SpeakerSampler {
    private let ciContext = CIContext(options: nil)

    public init() {}

    /// Produce a speaker sample for a frame at the given meeting-relative timestamp.
    public func sample(_ pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) async -> SpeakerSample {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent

        // 1. Find candidate participant tiles.
        let tiles = await detectTiles(in: pixelBuffer)
        guard !tiles.isEmpty else {
            return SpeakerSample(timestamp: timestamp, speakerName: nil)
        }

        // 2. Score each tile's border for the active-speaker highlight; pick the best.
        let scored = tiles.map { (rect: $0, score: highlightScore(of: $0, in: image, extent: extent)) }
        let region: CGRect
        if let active = scored.max(by: { $0.score < $1.score }), active.score > highlightThreshold {
            // A clear active-speaker highlight → read that tile.
            region = active.rect
        } else if let dominant = Self.dominantTile(tiles) {
            // No highlight, but one tile clearly dominates the frame — a 1-on-1 or
            // speaker view where the lone remote participant has no "speaking ring".
            // Read their name anyway (the user's #1 reason names were never picked up).
            region = dominant
        } else {
            // A quiet gallery of similar tiles: who's named is ambiguous → skip.
            return SpeakerSample(timestamp: timestamp, speakerName: nil)
        }

        // 3. OCR the name label inside the chosen tile.
        let name = await recognizeName(in: pixelBuffer, regionOfInterest: region)
        return SpeakerSample(timestamp: timestamp, speakerName: name)
    }

    /// The single tile that clearly dominates the frame (a 1-on-1 / speaker view),
    /// or nil when tiles are similar-sized (a gallery, where no highlight means the
    /// active speaker is genuinely ambiguous). A lone tile is dominant; otherwise
    /// the largest must be at least 1.5× the area of the next-largest.
    static func dominantTile(_ tiles: [CGRect]) -> CGRect? {
        let sorted = tiles.sorted { $0.width * $0.height > $1.width * $1.height }
        guard let largest = sorted.first else { return nil }
        guard sorted.count > 1 else { return largest }
        let secondArea = sorted[1].width * sorted[1].height
        let largestArea = largest.width * largest.height
        return largestArea >= 1.5 * secondArea ? largest : nil
    }

    // MARK: - Tiles

    /// Detect rectangular tiles. Falls back to the whole frame if none are found
    /// (e.g. single-speaker view), so OCR still has a region to read.
    private func detectTiles(in pixelBuffer: CVPixelBuffer) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, _ in
                let rects = (request.results as? [VNRectangleObservation])?.map(\.boundingBox) ?? []
                continuation.resume(returning: rects.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : rects)
            }
            request.minimumAspectRatio = 0.3
            request.maximumObservations = 16
            request.minimumSize = 0.1
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Highlight scoring

    private let highlightThreshold: CGFloat = 0.15

    /// Average saturation*brightness along the tile's border band, in normalized
    /// (Vision) coordinates. A speaking ring pushes this well above a quiet tile.
    private func highlightScore(of normalizedRect: CGRect, in image: CIImage, extent: CGRect) -> CGFloat {
        // Convert normalized rect (origin bottom-left) to image pixel coordinates.
        let rect = CGRect(
            x: extent.origin.x + normalizedRect.origin.x * extent.width,
            y: extent.origin.y + normalizedRect.origin.y * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        )
        // Sample a thin border band by averaging the outer frame of the tile.
        let band = max(2, min(rect.width, rect.height) * 0.04)
        let edges = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: band),               // bottom
            CGRect(x: rect.minX, y: rect.maxY - band, width: rect.width, height: band),         // top
            CGRect(x: rect.minX, y: rect.minY, width: band, height: rect.height),               // left
            CGRect(x: rect.maxX - band, y: rect.minY, width: band, height: rect.height),        // right
        ]
        let scores = edges.map { averageVividness(of: image.cropped(to: $0)) }
        return scores.reduce(0, +) / CGFloat(scores.count)
    }

    /// Average "vividness" (saturation × brightness) of a region via CIAreaAverage.
    private func averageVividness(of region: CIImage) -> CGFloat {
        guard !region.extent.isInfinite, !region.extent.isEmpty else { return 0 }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: region,
            kCIInputExtentKey: CIVector(cgRect: region.extent),
        ])
        guard let output = filter?.outputImage else { return 0 }
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = CGFloat(bitmap[0]) / 255, g = CGFloat(bitmap[1]) / 255, b = CGFloat(bitmap[2]) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
        let brightness = maxC
        return saturation * brightness
    }

    // MARK: - OCR

    /// OCR the lower strip of the active tile (where name labels usually sit) and
    /// return the most plausible participant name.
    private func recognizeName(in pixelBuffer: CVPixelBuffer, regionOfInterest: CGRect) async -> String? {
        // Name labels typically occupy the bottom ~20% of a tile.
        let nameStrip = CGRect(
            x: regionOfInterest.minX,
            y: regionOfInterest.minY,
            width: regionOfInterest.width,
            height: max(0.05, regionOfInterest.height * 0.2)
        )
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: Self.bestName(from: lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Recognize both Chinese (simplified + traditional) and English names.
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.regionOfInterest = nameStrip
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }

    /// Pick the most name-like line: short, mostly letters, not a UI control word.
    static func bestName(from lines: [String]) -> String? {
        let noise: Set<String> = [
            // English controls
            "mute", "unmute", "you", "stop video", "start video", "more", "chat", "raise hand",
            // Mandarin controls (traditional + simplified)
            "靜音", "静音", "取消靜音", "取消静音", "停止視訊", "停止视频",
            "開始視訊", "开始视频", "更多", "聊天", "舉手", "举手", "你", "我",
        ]
        let candidates = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                guard line.count >= 2, line.count <= 40 else { return false }
                guard !noise.contains(lower) else { return false }
                let letters = line.filter { $0.isLetter }.count
                return letters >= line.count / 2
            }
        // Prefer the longest plausible line (full names beat single tokens).
        return candidates.max(by: { $0.count < $1.count })
    }
}
