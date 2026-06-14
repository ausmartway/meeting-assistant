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

/// Local summarizer. An actor so the model weights are loaded once and reused
/// across the many calls map-reduce makes for a long meeting. Each call uses a
/// FRESH `ChatSession` (independent KV cache) with a capped output length, so
/// per-call memory stays bounded — long meetings summarize within the same
/// memory envelope as short ones (works on 16 GB).
public actor MLXSummarizer: Summarizing {
    private let modelID: String
    private var modelContext: ModelContext?

    /// A small instruct model is plenty for summaries and stays light on RAM
    /// (~1.7 GB at 4-bit).
    public init(modelID: String = "mlx-community/Qwen2.5-3B-Instruct-4bit") {
        self.modelID = modelID
    }

    private func context() async throws -> ModelContext {
        if let modelContext { return modelContext }
        let ctx = try await loadModel(id: modelID)
        modelContext = ctx
        return ctx
    }

    public func summarize(transcript: String, meetingTitle: String) async throws -> MeetingSummary {
        let ctx = try await context()
        // Fresh session per call → no KV cache growth across chunks. Cap output
        // so a single summary can't run away in tokens/memory.
        let session = ChatSession(ctx, generateParameters: GenerateParameters(maxTokens: 800))
        let raw = try await session.respond(
            to: SummarizationPrompt.build(transcript: transcript, title: meetingTitle)
        )
        return SummarizationPrompt.parse(raw)
    }
}
#endif
