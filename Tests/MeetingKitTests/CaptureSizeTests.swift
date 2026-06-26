import CoreGraphics
import Testing

@testable import MeetingKit

@Suite("CaptureSession.captureSize")
struct CaptureSizeTests {
    @Test("scales by backing factor when under the cap")
    func underCap() {
        let (w, h) = CaptureSession.captureSize(
            for: CGSize(width: 400, height: 300), scale: 2, cap: 1920)
        #expect(w == 800)
        #expect(h == 600)
    }

    @Test("caps the longest side and preserves aspect ratio")
    func cappedAspect() {
        let (w, h) = CaptureSession.captureSize(
            for: CGSize(width: 2000, height: 1000), scale: 2, cap: 1920)
        #expect(w == 1920)
        #expect(h == 960)
    }
}
