import Foundation
import AVFoundation

/// A fixed passage the user reads aloud during voice enrollment. A neutral,
/// phonetically varied paragraph (~20 s) gives the diarizer a clean voiceprint.
public enum EnrollmentScript {
    public static let passage = """
    Thanks for setting up the meeting assistant. To help it tell voices apart, \
    please read this short paragraph in your normal speaking voice. The quick \
    brown fox jumps over the lazy dog near the river bank. I usually join calls \
    from my office, sometimes from home, and occasionally while travelling. \
    That should be plenty for the app to learn how I sound.
    """
}

/// Records a short mic clip (~20 s, 16 kHz mono WAV) for voice enrollment, written
/// to a caller-supplied URL. Used by Settings/onboarding so the diarizer can learn
/// the local user's voiceprint ("Me").
@MainActor
final class EnrollmentRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var destination: URL?

    /// Record up to `seconds` of audio to `url`, then call `completion` on the main actor.
    func record(to url: URL, seconds: TimeInterval = 20, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            self.recorder = rec
            self.onFinish = completion
            self.destination = url
            rec.record(forDuration: seconds)
            isRecording = true
        } catch {
            completion(.failure(error))
        }
    }

    /// Stop early (user pressed "Stop").
    func stop() { recorder?.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            guard let dest = self.destination else { return }
            self.onFinish?(flag ? .success(dest) : .failure(NSError(domain: "Enrollment", code: 1)))
            self.recorder = nil
            self.onFinish = nil
            self.destination = nil
        }
    }
}
