import Foundation
import MeetingKit

/// Which engine produces summaries. Mirrors the user's "local with optional
/// Claude" choice: local by default, Claude on demand.
enum SummaryEngine: String, CaseIterable, Identifiable {
    case local
    case claude
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local: return "Local (private)"
        case .claude: return "Claude API"
        }
    }
}

/// User preferences, persisted in UserDefaults. The Claude API key lives in the
/// Keychain (see `KeychainStore`), not here.
@MainActor
final class AppSettings: ObservableObject {
    @Published var transcriptionModel: TranscriptionModel {
        didSet { defaults.set(transcriptionModel.rawValue, forKey: Keys.transcriptionModel) }
    }
    @Published var summaryEngine: SummaryEngine {
        didSet { defaults.set(summaryEngine.rawValue, forKey: Keys.summaryEngine) }
    }
    @Published var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Keys.claudeModel) }
    }
    @Published var hasClaudeKey: Bool

    private let defaults: UserDefaults

    enum Keys {
        static let transcriptionModel = "transcriptionModel"
        static let summaryEngine = "summaryEngine"
        static let claudeModel = "claudeModel"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: Keys.transcriptionModel) ?? ""
        ) ?? .largeTurbo
        self.summaryEngine = SummaryEngine(
            rawValue: defaults.string(forKey: Keys.summaryEngine) ?? ""
        ) ?? .local
        // Default to the most capable model per Anthropic guidance.
        self.claudeModel = defaults.string(forKey: Keys.claudeModel) ?? "claude-opus-4-8"
        self.hasClaudeKey = KeychainStore.loadAPIKey() != nil
    }

    func setClaudeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.deleteAPIKey()
            hasClaudeKey = false
        } else {
            KeychainStore.saveAPIKey(trimmed)
            hasClaudeKey = true
        }
    }

    /// Build the summarizer the user has selected. Falls back to the local engine
    /// when Claude is selected but no key is set.
    func makeSummarizer() -> Summarizing {
        switch summaryEngine {
        case .claude:
            if let key = KeychainStore.loadAPIKey() {
                return ClaudeSummarizer(apiKey: key, model: claudeModel)
            }
            return Backends.makeLocalSummarizer()
        case .local:
            return Backends.makeLocalSummarizer()
        }
    }

    /// Build the on-device transcriber (real WhisperKit when compiled in).
    func makeTranscriber() -> Transcribing {
        Backends.makeTranscriber(model: transcriptionModel)
    }
}
