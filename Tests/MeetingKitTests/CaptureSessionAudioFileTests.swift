import AVFoundation
import Testing

@testable import MeetingKit

@Suite("CaptureSession audio file format")
struct CaptureSessionAudioFileTests {

    @Test("recorded WAVs store 16-bit integer PCM (half the size of 32-bit float)")
    func writesSixteenBitIntegerPCM() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-pcm16-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // Capture happens in float32 internally; the file should encode it as int16.
        let processing = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        // Scope the writer so AVAudioFile flushes to disk (on dealloc) before we reopen.
        do {
            let file = try CaptureSession.makePCM16File(at: url, processingFormat: processing)
            let buf = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 1_600)!
            buf.frameLength = 1_600
            let ch = buf.floatChannelData![0]
            for i in 0..<1_600 { ch[i] = Float(0.1 * sin(Double(i) * 0.1)) }
            try file.write(from: buf)
        }

        let read = try AVAudioFile(forReading: url)
        #expect(read.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(read.fileFormat.sampleRate == 16_000)
        #expect(read.fileFormat.channelCount == 1)
        #expect(read.length == 1_600)
    }
}
