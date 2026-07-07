import Foundation
import Testing

@testable import MeetingKit

@Suite("VoiceSample / KnownSpeaker migration")
struct VoiceSampleTests {

    @Test("embedding convenience init becomes a single 30s sample")
    func convenienceInit() {
        let s = KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0])
        #expect(s.samples.count == 1)
        #expect(s.samples[0].embedding == [1, 0, 0])
        #expect(s.samples[0].seconds == 30)
    }

    @Test("legacy JSON (single embedding, no samples) migrates on decode")
    func legacyDecode() throws {
        let legacy = """
            [{"id": "8B29A9F5-97A2-4B47-8A9B-4D9E27E5B111", "name": "Sam",
              "isMe": false, "embedding": [1, 0, 0],
              "updatedAt": 700000000}]
            """
        let decoded = try JSONDecoder().decode([KnownSpeaker].self, from: Data(legacy.utf8))
        #expect(decoded[0].samples.count == 1)
        #expect(decoded[0].samples[0].embedding == [1, 0, 0])
        #expect(decoded[0].samples[0].seconds == 30)
    }

    @Test("current format round-trips with multiple samples")
    func roundTrip() throws {
        var speaker = KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0])
        speaker.samples.append(
            VoiceSample(
                embedding: [0, 1, 0], seconds: 120, addedAt: Date(timeIntervalSince1970: 1)))
        let data = try JSONEncoder().encode([speaker])
        let decoded = try JSONDecoder().decode([KnownSpeaker].self, from: data)
        #expect(decoded[0].samples == speaker.samples)
    }
}
