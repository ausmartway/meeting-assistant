import Foundation
import AVFoundation
import ScreenCaptureKit
import os

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

    /// Fixed format for `mic.wav` (16 kHz mono — matches `system.wav` + Whisper).
    /// Every input buffer is converted to this before writing, so a mid-call input
    /// change (e.g. AirPods switching A2DP↔HFP when the mic engages) can't corrupt
    /// the file even if the hardware format changes.
    private let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var micConverter: AVAudioConverter?
    private var configChangeObserver: NSObjectProtocol?
    private let micStateLock = NSLock()
    private var micFramesWritten = 0
    private static let log = Logger(subsystem: "MeetingAssistant", category: "capture")

    /// Called when live capture notices a problem the user should know about
    /// mid-meeting (e.g. the mic is producing no audio). Wired to the app UI.
    public var onWarning: (@Sendable (String) -> Void)?

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
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        micConverter = nil
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
        // Write at the FIXED mic format so route/format changes during the call
        // can't break the file; input buffers are converted to it in the tap.
        micFile = try AVAudioFile(forWriting: url, settings: micFormat.settings)

        // AVAudioEngine STOPS when the audio route changes — a Bluetooth device
        // connecting, AirPods switching A2DP↔HFP as the mic engages for a call, a
        // sample-rate change. Without handling this the mic tap goes silent for the
        // rest of the meeting (exactly how a previous AirPods recording lost the
        // local voice). Reconfigure + restart whenever it fires.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        try installMicTap()
        audioEngine.prepare()
        try audioEngine.start()
        let fmt = audioEngine.inputNode.outputFormat(forBus: 0)
        Self.log.info("Mic capture started; input \(fmt.sampleRate, privacy: .public) Hz, \(fmt.channelCount, privacy: .public) ch")
        scheduleMicWatchdog()
    }

    /// (Re)build the converter for the current input format and install the tap.
    /// Idempotent and safe to call again after a configuration change.
    private func installMicTap() throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let nativeFormat = input.outputFormat(forBus: 0)
        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            Self.log.error("Mic input has an invalid format (\(nativeFormat.channelCount, privacy: .public) ch, \(nativeFormat.sampleRate, privacy: .public) Hz) — no input device?")
            onWarning?("No microphone input is available. Check your input device in System Settings → Sound.")
            return
        }
        // Plain tap (no voice processing) keeps the mic a clean, separate signal —
        // exactly what the fuser needs to label the local user as "Me". The buffer
        // is converted to the fixed mic format before it's written.
        micConverter = AVAudioConverter(from: nativeFormat, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.writeMic(buffer)
        }
    }

    private func handleConfigurationChange() {
        Self.log.info("Audio configuration changed; reconfiguring mic capture.")
        do {
            try installMicTap()
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
        } catch {
            Self.log.error("Failed to restart mic after configuration change: \(error.localizedDescription, privacy: .public)")
            onWarning?("The microphone stopped after an audio device change and couldn't restart.")
        }
    }

    /// Convert one input buffer to the fixed mic format and append it to `mic.wav`.
    private func writeMic(_ buffer: AVAudioPCMBuffer) {
        guard let converter = micConverter, let file = micFile,
              let out = Self.convert(buffer, using: converter, to: micFormat) else { return }
        try? file.write(from: out)
        micStateLock.lock(); micFramesWritten += Int(out.frameLength); micStateLock.unlock()
    }

    /// Resample/convert one PCM buffer to `format` in a single shot, returning nil
    /// if the input is empty or nothing came out. Pure (no instance state) so the
    /// resampling that `mic.wav` depends on is unit-testable without audio hardware.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        var convertError: NSError?
        converter.convert(to: out, error: &convertError, withInputFrom: inputBlock)
        return out.frameLength > 0 ? out : nil
    }

    /// A few seconds in, warn if the mic has produced no audio at all — so the user
    /// can fix their input device mid-meeting instead of discovering it afterwards.
    private func scheduleMicWatchdog() {
        outputQueue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.micStateLock.lock(); let frames = self.micFramesWritten; self.micStateLock.unlock()
            guard frames == 0 else { return }
            Self.log.error("Microphone produced no audio 6s into the meeting.")
            self.onWarning?("Your microphone isn't being recorded — no audio detected. If you're on AirPods/Bluetooth, select them as the input in System Settings → Sound, then stop and start recording.")
        }
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
