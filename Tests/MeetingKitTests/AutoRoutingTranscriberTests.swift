import Foundation
import Testing

@testable import MeetingKit

@Suite("AutoRoutingTranscriber")
struct AutoRoutingTranscriberTests {

    // Detector that returns a preset language.
    private struct StubDetector: LanguageDetecting {
        let result: DetectedLanguage?
        func detectLanguage(audioFile: URL) async throws -> DetectedLanguage? { result }
    }

    // Engine that records whether it was called and tags its name into the segment.
    private actor SpyEngine: Transcribing {
        let name: String
        private(set) var lastHint: String??
        init(name: String) { self.name = name }
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func setConcurrentWorkers(_ count: Int) async {}
        func transcribe(audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?)
            async throws -> [TranscriptSegment]
        {
            [TranscriptSegment(start: 0, end: 1, text: name, channel: channel)]
        }
        func transcribe(
            audioFile: URL, channel: AudioChannel, languageHint: String?,
            progress: TranscribeProgressHandler?
        ) async throws -> [TranscriptSegment] {
            lastHint = languageHint
            return [TranscriptSegment(start: 0, end: 1, text: name, channel: channel)]
        }
        func recordedHint() -> String?? { lastHint }
    }

    private func url() -> URL { URL(fileURLWithPath: "/tmp/x.wav") }

    @Test("English routes to Parakeet with the language hint")
    func englishToParakeet() async throws {
        let whisper = SpyEngine(name: "whisper")
        let parakeet = SpyEngine(name: "parakeet")
        let auto = AutoRoutingTranscriber(
            detector: StubDetector(result: DetectedLanguage(code: "en", confidence: 0.9)),
            whisper: whisper, parakeet: parakeet
        )
        let segs = try await auto.transcribe(audioFile: url(), channel: .system, progress: nil)
        #expect(segs.first?.text == "parakeet")
        #expect(await parakeet.recordedHint() == .some("en"))
    }

    @Test("Mandarin routes to WhisperKit")
    func mandarinToWhisper() async throws {
        let whisper = SpyEngine(name: "whisper")
        let parakeet = SpyEngine(name: "parakeet")
        let auto = AutoRoutingTranscriber(
            detector: StubDetector(result: DetectedLanguage(code: "zh", confidence: 0.99)),
            whisper: whisper, parakeet: parakeet
        )
        let segs = try await auto.transcribe(audioFile: url(), channel: .microphone, progress: nil)
        #expect(segs.first?.text == "whisper")
    }

    // Records the global order of prefetch/prepare calls across engines.
    private actor CallLog {
        private(set) var calls: [String] = []
        func record(_ name: String) { calls.append(name) }
    }

    // Detector that can also be prepared, logging the call.
    private struct LoggingDetector: LanguageDetecting, Transcribing {
        let log: CallLog
        func detectLanguage(audioFile: URL) async throws -> DetectedLanguage? { nil }
        func prepare(progress: TranscribeProgressHandler?) async throws {
            await log.record("detector.prepare")
        }
        func transcribe(
            audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?
        ) async throws -> [TranscriptSegment] { [] }
    }

    // Engine whose prefetch logs itself and optionally fails.
    private struct LoggingEngine: Transcribing {
        let name: String
        let log: CallLog
        var prefetchError: Error? = nil
        func prepare(progress: TranscribeProgressHandler?) async throws {}
        func prefetch(progress: TranscribeProgressHandler?) async throws {
            await log.record("\(name).prefetch")
            if let prefetchError { throw prefetchError }
        }
        func transcribe(
            audioFile: URL, channel: AudioChannel, progress: TranscribeProgressHandler?
        ) async throws -> [TranscriptSegment] { [] }
    }

    @Test("prefetch prepares the detector, then downloads Parakeet, then Whisper")
    func prefetchOrder() async throws {
        let log = CallLog()
        let auto = AutoRoutingTranscriber(
            detector: LoggingDetector(log: log),
            whisper: LoggingEngine(name: "whisper", log: log),
            parakeet: LoggingEngine(name: "parakeet", log: log)
        )
        try await auto.prefetch(progress: nil)
        #expect(await log.calls == ["detector.prepare", "parakeet.prefetch", "whisper.prefetch"])
    }

    @Test("prefetch fails fast: a Parakeet download error skips the Whisper download")
    func prefetchFailFast() async throws {
        struct Boom: Error {}
        let log = CallLog()
        let auto = AutoRoutingTranscriber(
            detector: LoggingDetector(log: log),
            whisper: LoggingEngine(name: "whisper", log: log),
            parakeet: LoggingEngine(name: "parakeet", log: log, prefetchError: Boom())
        )
        await #expect(throws: Boom.self) { try await auto.prefetch(progress: nil) }
        #expect(await log.calls == ["detector.prepare", "parakeet.prefetch"])
    }

    @Test("detector returning nil routes to WhisperKit")
    func nilDetectionToWhisper() async throws {
        let whisper = SpyEngine(name: "whisper")
        let parakeet = SpyEngine(name: "parakeet")
        let auto = AutoRoutingTranscriber(
            detector: StubDetector(result: nil),
            whisper: whisper, parakeet: parakeet
        )
        let segs = try await auto.transcribe(audioFile: url(), channel: .system, progress: nil)
        #expect(segs.first?.text == "whisper")
    }
}
