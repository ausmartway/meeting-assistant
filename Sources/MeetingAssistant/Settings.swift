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

    /// Show a Dock icon as an always-visible way to reach the app. On by default
    /// so the app is always reachable even when the menu-bar icon is hidden for
    /// lack of space (e.g. a notched built-in laptop display); can be turned off
    /// for a clean menu-bar-only experience.
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    private let defaults: UserDefaults

    enum Keys {
        static let transcriptionModel = "transcriptionModel"
        static let transcriptionWorkers = "transcriptionWorkers"
        static let showDockIcon = "showDockIcon"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: Keys.transcriptionModel) ?? ""
        ) ?? .largeTurbo
        let stored = defaults.integer(forKey: Keys.transcriptionWorkers) // 0 when unset
        self.transcriptionWorkers = Self.workerRange.contains(stored) ? stored : 4
        // Default ON the first time (key absent); respect the user's choice after.
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) == nil
            ? true
            : defaults.bool(forKey: Keys.showDockIcon)
    }

    /// Build the on-device transcriber (real WhisperKit when compiled in).
    func makeTranscriber() -> Transcribing {
        Backends.makeTranscriber(model: transcriptionModel, workers: transcriptionWorkers)
    }
}
