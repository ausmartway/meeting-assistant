import Testing
import AVFoundation
@testable import MeetingKit

@Suite("CaptureSession.convert (mic resampling)")
struct CaptureSessionConvertTests {

    private let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    /// A buffer of `frames` at `rate` filled with a quiet tone so it isn't empty.
    private func toneBuffer(rate: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = Float(0.1 * sin(Double(i) * 0.1)) }
        return buf
    }

    @Test("48 kHz input downsamples to ~1/3 the frames at 16 kHz, non-empty")
    func downsamples48to16() throws {
        let input = toneBuffer(rate: 48_000, frames: 4_800)   // 0.1 s of audio
        let converter = try #require(AVAudioConverter(from: input.format, to: micFormat))
        let out = try #require(CaptureSession.convert(input, using: converter, to: micFormat))
        #expect(out.format.sampleRate == 16_000)
        // 0.1 s at 16 kHz ≈ 1600 frames; allow generous slack for converter priming.
        #expect(out.frameLength > 1_000)
        #expect(out.frameLength < 2_400)
    }

    @Test("an empty input buffer yields nil (nothing to write)")
    func emptyInputIsNil() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let empty = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
        empty.frameLength = 0
        let converter = try #require(AVAudioConverter(from: fmt, to: micFormat))
        #expect(CaptureSession.convert(empty, using: converter, to: micFormat) == nil)
    }

    @Test("same-rate input passes through non-empty")
    func sameRatePassthrough() throws {
        let input = toneBuffer(rate: 16_000, frames: 1_600)
        let converter = try #require(AVAudioConverter(from: input.format, to: micFormat))
        let out = try #require(CaptureSession.convert(input, using: converter, to: micFormat))
        #expect(out.frameLength > 0)
    }
}
