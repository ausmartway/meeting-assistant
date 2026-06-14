import Foundation
import AVFoundation
import ScreenCaptureKit

/// The only component that runs *during* a meeting, and it stays deliberately
/// lightweight (cheap live capture, heavy post-processing — see the design):
///
///  • System audio (remote participants) via ScreenCaptureKit → `system.wav`
///  • Microphone (local user) via AVAudioEngine → `mic.wav`
///  • One video frame every few seconds → `SpeakerSampler` → speaker timeline
///
/// Transcription and speaker labeling happen afterwards from the files this
/// writes, keeping the machine responsive while the user is on the call.
@available(macOS 14.0, *)
public final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {

    /// How often to sample a video frame for active-speaker detection.
    public var frameSampleInterval: TimeInterval = 2.5

    private let meeting: Meeting
    private let store: MeetingStore
    private let sampler: SpeakerSampler

    private var stream: SCStream?
    private let audioEngine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?

    private let startWallClock = Date()
    private var lastFrameSample: TimeInterval = -.greatestFiniteMagnitude
    private var samples: [SpeakerSample] = []
    private let sampleQueue = DispatchQueue(label: "meetingassistant.capture.samples")
    private let outputQueue = DispatchQueue(label: "meetingassistant.capture.output")

    public init(meeting: Meeting, store: MeetingStore, sampler: SpeakerSampler = SpeakerSampler()) {
        self.meeting = meeting
        self.store = store
        self.sampler = sampler
    }

    // MARK: - Lifecycle

    /// Begin capturing. Requires Screen Recording and Microphone permissions to
    /// have been granted already (handled by onboarding).
    public func start() async throws {
        let dir = try store.directory(for: meeting.id)

        try startMicrophoneCapture(into: dir.appendingPathComponent("mic.wav"))
        try await startSystemCapture(systemAudioURL: dir.appendingPathComponent("system.wav"))
    }

    /// Stop capturing and persist the recording metadata + speaker timeline.
    public func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        micFile = nil
        systemFile = nil

        let timeline = SpeakerTimeline(samples: sampleQueue.sync { samples })
        let recording = MeetingRecording(
            meeting: meeting,
            recordedAt: startWallClock,
            micAudioFile: "mic.wav",
            systemAudioFile: "system.wav",
            timeline: timeline
        )
        try store.save(recording)
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophoneCapture(into url: URL) throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        micFile = file

        // Plain tap (no voice processing) keeps the mic channel a clean, separate
        // signal — exactly what the fuser needs to label the local user as "Me".
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.micFile?.write(from: buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - System audio + frames (ScreenCaptureKit)

    private func startSystemCapture(systemAudioURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't record our own output
        config.sampleRate = 16_000                   // matches Whisper's expected input
        config.channelCount = 1
        // Modest video — we only sample a frame every few seconds for OCR.
        config.width = 1280
        config.height = 720
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // ~2 fps ceiling

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        self.stream = stream

        try await stream.startCapture()
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            handleSystemAudio(sampleBuffer)
        case .screen:
            handleVideoFrame(sampleBuffer)
        default:
            break
        }
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = sampleBuffer.pcmBuffer else { return }
        do {
            if systemFile == nil {
                let dir = try store.directory(for: meeting.id)
                systemFile = try AVAudioFile(
                    forWriting: dir.appendingPathComponent("system.wav"),
                    settings: pcm.format.settings
                )
            }
            try systemFile?.write(from: pcm)
        } catch {
            // Non-fatal: a dropped audio buffer shouldn't tear down the meeting.
        }
    }

    private func handleVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        let elapsed = Date().timeIntervalSince(startWallClock)
        guard elapsed - lastFrameSample >= frameSampleInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameSample = elapsed

        // Run the (best-effort) speaker read off the capture queue.
        Task { [weak self] in
            guard let self else { return }
            let sample = await self.sampler.sample(pixelBuffer, at: elapsed)
            self.sampleQueue.sync { self.samples.append(sample) }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Surfaced to the coordinator via delegate in a fuller implementation.
    }

    public enum CaptureError: Error {
        case noDisplay
    }
}
