import Foundation
import Testing

@testable import MeetingKit

@Suite("SlideKeyframe + MeetingRecording decoding")
struct SlideKeyframeDecodingTests {

    private func meeting() -> Meeting {
        Meeting(
            id: "m1", title: "Sync", startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 1800), provider: nil, joinURL: nil)
    }

    @Test("a recording.json written before slides existed decodes with no slides")
    func legacyRecordingDecodes() throws {
        // Exactly the shape written before this feature: no `slides` key at all.
        let json = """
            {
              "meeting": {
                "id": "m1", "title": "Sync",
                "startDate": "1970-01-01T00:00:00Z", "endDate": "1970-01-01T00:30:00Z"
              },
              "recordedAt": "1970-01-01T00:00:00Z",
              "micAudioFile": "mic.wav",
              "systemAudioFile": "system.wav",
              "timeline": { "samples": [] }
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(MeetingRecording.self, from: Data(json.utf8))
        #expect(rec.slides.isEmpty)
        #expect(rec.micAudioFile == "mic.wav")
    }

    @Test("slides round-trip through encode and decode")
    func slidesRoundTrip() throws {
        let rec = MeetingRecording(
            meeting: meeting(), recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: []),
            slides: [
                SlideKeyframe(timestamp: 391, file: "slides/slide-0391.jpg"),
                SlideKeyframe(timestamp: 512, file: "slides/slide-0512.jpg"),
            ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(MeetingRecording.self, from: try encoder.encode(rec))
        #expect(back.slides.count == 2)
        #expect(back.slides[0].file == "slides/slide-0391.jpg")
        #expect(back.slides[1].timestamp == 512)
    }

    @Test("omitting slides at the call site keeps existing callers working")
    func slidesDefaultToEmpty() {
        let rec = MeetingRecording(
            meeting: meeting(), recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: []))
        #expect(rec.slides.isEmpty)
    }
}
