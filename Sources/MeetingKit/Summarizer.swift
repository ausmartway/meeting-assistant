import Foundation

/// The product of summarization: a short prose summary plus extracted action items.
public struct MeetingSummary: Codable, Sendable, Equatable {
    public let summary: String
    public let actionItems: [String]

    public init(summary: String, actionItems: [String]) {
        self.summary = summary
        self.actionItems = actionItems
    }

    /// Render as Markdown for the `summary.md` file in a meeting bundle.
    public func markdown() -> String {
        var out = "## Summary\n\n\(summary)\n"
        if !actionItems.isEmpty {
            out += "\n## Action Items\n\n"
            out += actionItems.map { "- [ ] \($0)" }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }
}

/// Produces a summary + action items from a finished transcript.
///
/// Two real backends are intended: a local LLM (MLX, default, fully private) and
/// the Claude API (opt-in, higher quality). The local one needs the full Xcode
/// Metal toolchain to build, so it is a swap-in; `ClaudeSummarizer` works today
/// over plain HTTP, and `StubSummarizer` keeps the pipeline runnable offline.
public protocol Summarizing: Sendable {
    func summarize(transcript: String, meetingTitle: String) async throws -> MeetingSummary
}

/// Offline placeholder producing a trivial extractive summary so the pipeline
/// yields a `summary.md` even before an LLM backend is configured.
public struct StubSummarizer: Summarizing {
    public init() {}

    public func summarize(transcript: String, meetingTitle: String) async throws -> MeetingSummary {
        let firstLines = transcript
            .split(separator: "\n")
            .prefix(3)
            .joined(separator: " ")
        return MeetingSummary(
            summary: "Summary backend not configured. Transcript preview: \(firstLines)",
            actionItems: []
        )
    }
}

// MARK: - Local LLM (compiled only when MLX is available)

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon

public struct MLXSummarizer: Summarizing {
    private let modelID: String

    /// A small instruct model is plenty for summaries and stays light on RAM
    /// (~2–3 GB at 4-bit), per the design notes.
    public init(modelID: String = "mlx-community/Qwen2.5-3B-Instruct-4bit") {
        self.modelID = modelID
    }

    public func summarize(transcript: String, meetingTitle: String) async throws -> MeetingSummary {
        // Downloads + compiles the model on first use, then runs fully on-device.
        let model = try await loadModel(id: modelID)
        let session = ChatSession(model)
        let raw = try await session.respond(
            to: SummarizationPrompt.build(transcript: transcript, title: meetingTitle)
        )
        return SummarizationPrompt.parse(raw)
    }
}
#endif
