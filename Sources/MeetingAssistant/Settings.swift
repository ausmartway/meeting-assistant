import Foundation
import MeetingKit

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    /// Sensible bounds for the VAD decode parallelism (see Settings help text).
    static let workerRange = 1...8

    @Published var transcriptionModel: TranscriptionModel {
        didSet { defaults.set(transcriptionModel.rawValue, forKey: Keys.transcriptionModel) }
    }

    /// How many VAD chunks WhisperKit decodes in parallel. 4 is the sweet spot on
    /// an M1 Pro (good throughput without saturating the single GPU); higher hits
    /// diminishing returns, lower is gentler on the machine during other work.
    @Published var transcriptionWorkers: Int {
        didSet { defaults.set(transcriptionWorkers, forKey: Keys.transcriptionWorkers) }
    }

    private let defaults: UserDefaults

    enum Keys {
        static let transcriptionModel = "transcriptionModel"
        static let transcriptionWorkers = "transcriptionWorkers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: Keys.transcriptionModel) ?? ""
        ) ?? .largeTurbo
        let stored = defaults.integer(forKey: Keys.transcriptionWorkers) // 0 when unset
        self.transcriptionWorkers = Self.workerRange.contains(stored) ? stored : 4
    }

    /// Build the on-device transcriber (real WhisperKit when compiled in).
    func makeTranscriber() -> Transcribing {
        Backends.makeTranscriber(model: transcriptionModel, workers: transcriptionWorkers)
    }
}
