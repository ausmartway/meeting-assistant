import Foundation

/// A user-initiated operation that can fail. Used to turn raw framework errors
/// into plain-English messages with a concrete next step, so the UI never shows
/// codes like `NSCocoaErrorDomain Code=4` to a non-technical user.
public enum AppOperation: Sendable {
    case startRecording
    case stopRecording
    case transcribing
    case modelDownload
}

/// Map an operation (and its underlying error, used only for logging) to a
/// short, plain-English message that always tells the user what to do next.
/// Deliberately ignores the raw error text so no jargon leaks into the UI.
public func userFacingMessage(for operation: AppOperation, error: Error? = nil) -> String {
    switch operation {
    case .startRecording:
        return
            "Couldn’t start recording. Open Settings and make sure Screen Recording and Microphone access are turned on."
    case .stopRecording:
        return
            "Something went wrong while finishing up. Your audio was saved — open the meeting and choose “Transcript Again.”"
    case .transcribing:
        return
            "Couldn’t finish the transcript. Your audio is saved — open the meeting and choose “Transcript Again.”"
    case .modelDownload:
        return
            "Couldn’t download the transcription model. Check your internet connection, then try again."
    }
}
