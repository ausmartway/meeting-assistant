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

    /// Which transcription engine to use. WhisperKit by default (multilingual);
    /// Parakeet is an English-first, much faster Apple-Silicon engine.
    @Published var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
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

    /// Whether to run on-device diarization to attach names to in-room speakers
    /// (people sharing the local mic). Off by default — it adds a post-processing
    /// pass and only helps when several people are in the room together.
    @Published var identifyInRoomSpeakers: Bool {
        didSet { defaults.set(identifyInRoomSpeakers, forKey: Keys.identifyInRoomSpeakers) }
    }

    private let defaults: UserDefaults

    /// The on-disk library of known speakers (voiceprints + names), shared across
    /// meetings so a person renamed once is recognized in future recordings.
    let speakerLibrary: SpeakerLibrary

    enum Keys {
        static let transcriptionModel = "transcriptionModel"
        static let transcriptionEngine = "transcriptionEngine"
        static let transcriptionWorkers = "transcriptionWorkers"
        static let showDockIcon = "showDockIcon"
        static let identifyInRoomSpeakers = "identifyInRoomSpeakers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: Keys.transcriptionModel) ?? ""
        ) ?? .largeTurbo
        // Parakeet is the default: ~100× faster on real speech with comparable
        // English accuracy (see docs/decisions/2026-06-17-transcription-engine.md).
        // WhisperKit stays selectable for Mandarin / other languages.
        self.transcriptionEngine = TranscriptionEngine(
            rawValue: defaults.string(forKey: Keys.transcriptionEngine) ?? ""
        ) ?? .parakeet
        let stored = defaults.integer(forKey: Keys.transcriptionWorkers) // 0 when unset
        self.transcriptionWorkers = Self.workerRange.contains(stored) ? stored : 4
        // Default ON the first time (key absent); respect the user's choice after.
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) == nil
            ? true
            : defaults.bool(forKey: Keys.showDockIcon)
        self.identifyInRoomSpeakers = defaults.bool(forKey: Keys.identifyInRoomSpeakers)

        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        self.speakerLibrary = SpeakerLibrary(url: base.appendingPathComponent("MeetingAssistant/speakers.json"))
    }

    /// Build the on-device transcriber for the selected engine.
    func makeTranscriber() -> Transcribing {
        Backends.makeTranscriber(
            engine: transcriptionEngine,
            model: transcriptionModel,
            workers: transcriptionWorkers
        )
    }

    /// Build the on-device diarizer (real FluidAudio when compiled in).
    func makeDiarizer() -> Diarizing {
        Backends.makeDiarizer()
    }

    /// Whether the local user has enrolled their own voice (so their mic segments
    /// can be labeled "Me" by the diarizer).
    var isEnrolled: Bool { speakerLibrary.me != nil }
}
