import Testing
import Foundation
@testable import MeetingKit

@Suite("Diarizer models & stub")
struct DiarizerStubTests {

    @Test("DiarizedSpan round-trips through Codable")
    func spanCodable() throws {
        let span = DiarizedSpan(start: 1.0, end: 2.5, speakerID: "Me")
        let data = try JSONEncoder().encode(span)
        let back = try JSONDecoder().decode(DiarizedSpan.self, from: data)
        #expect(back == span)
    }

    @Test("MeEnrollment round-trips through Codable")
    func enrollmentCodable() throws {
        let enrollment = MeEnrollment(
            audioFile: URL(fileURLWithPath: "/tmp/enroll.wav"),
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(enrollment)
        let back = try JSONDecoder().decode(MeEnrollment.self, from: data)
        #expect(back == enrollment)
    }

    @Test("StubDiarizer returns no spans so callers fall back to 'Me'")
    func stubReturnsEmpty() async throws {
        let stub = StubDiarizer()
        let spans = try await stub.diarize(
            audioFile: URL(fileURLWithPath: "/tmp/none.wav"),
            enrollment: nil,
            progress: nil
        )
        #expect(spans.isEmpty)
    }
}
