import Foundation
import Testing

@testable import MeetingKit

@Suite("UserFacingError")
struct UserFacingErrorTests {

    private struct Raw: Error { let code = 4 }

    @Test("messages never leak raw error codes or domains")
    func noJargon() {
        let ops: [AppOperation] = [.startRecording, .stopRecording, .transcribing, .modelDownload]
        for op in ops {
            let msg = userFacingMessage(for: op, error: Raw())
            #expect(!msg.isEmpty)
            #expect(!msg.contains("Error Domain"))
            #expect(!msg.contains("Code="))
            #expect(!msg.lowercased().contains("nscocoa"))
        }
    }

    @Test("start-recording failure points at the relevant permissions")
    func startRecordingGuidance() {
        let msg = userFacingMessage(for: .startRecording)
        #expect(msg.contains("Settings"))
        #expect(msg.contains("Screen Recording"))
        #expect(msg.contains("Microphone"))
    }

    @Test("processing failures reassure that audio is saved and offer a retry")
    func processingGuidance() {
        for op in [AppOperation.stopRecording, .transcribing] {
            let msg = userFacingMessage(for: op)
            #expect(msg.lowercased().contains("saved"))
            // References the exact button label users see in the meeting detail view.
            #expect(msg.contains("“Transcript Again.”"))
        }
    }

    @Test("model-download failure mentions the internet connection")
    func modelDownloadGuidance() {
        let msg = userFacingMessage(for: .modelDownload)
        #expect(msg.lowercased().contains("internet"))
    }
}
