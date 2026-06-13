import Foundation
import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Convert an audio `CMSampleBuffer` (as delivered by ScreenCaptureKit) into an
    /// `AVAudioPCMBuffer` suitable for writing to an `AVAudioFile`. Returns nil if
    /// the buffer isn't audio or the format can't be read.
    var pcmBuffer: AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        // Copy the sample data into the PCM buffer's audio buffer list.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
