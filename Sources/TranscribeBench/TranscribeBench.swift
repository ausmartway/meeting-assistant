import Foundation
import AVFoundation
import MeetingKit

// Compare WhisperKit vs Parakeet on one audio file: wall-clock, RTFx, and text.
// Usage: swift run TranscribeBench /path/to/audio.wav [whisperKit|parakeet|both]

@main
struct TranscribeBench {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: TranscribeBench <audio-file> [whisperKit|parakeet|auto|both]\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1])
        let which = args.count >= 3 ? args[2] : "both"

        let duration = audioDuration(url)
        print("File: \(url.lastPathComponent)  duration: \(String(format: "%.1f", duration))s\n")

        if which == "whisperKit" || which == "both" {
            await run(label: "WhisperKit", engine: .whisperKit, url: url, duration: duration)
        }
        if which == "parakeet" || which == "both" {
            await run(label: "Parakeet", engine: .parakeet, url: url, duration: duration)
        }
        if which == "auto" || which == "both" {
            await run(label: "Auto", engine: .auto, url: url, duration: duration)
        }
    }

    static func run(label: String, engine: TranscriptionEngine, url: URL, duration: Double) async {
        let t = Backends.makeTranscriber(engine: engine, model: .largeTurbo, workers: 4)
        do {
            try await t.prepare(progress: nil)
            let start = Date()
            let segments = try await t.transcribe(audioFile: url, channel: .system, progress: nil)
            let elapsed = Date().timeIntervalSince(start)
            let rtfx = elapsed > 0 ? duration / elapsed : 0
            let text = segments.map(\.text).joined(separator: " ")
            print("== \(label) ==")
            print(String(format: "  wall: %.2fs   RTFx: %.1fx   segments: %d", elapsed, rtfx, segments.count))
            print("  text: \(text.prefix(280))\n")
        } catch {
            print("== \(label) ==\n  ERROR: \(error)\n")
        }
    }

    static func audioDuration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
