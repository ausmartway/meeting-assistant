import Foundation

/// Summarizes a transcript of any length with bounded memory by map-reduce:
/// split into chunks, summarize each chunk, then summarize the chunk-summaries
/// into one final summary + action items. Each underlying model call sees only a
/// bounded amount of text, so a 2-hour meeting summarizes within the same memory
/// envelope as a 5-minute one — the key to running on a 16 GB machine.
///
/// Works with any `Summarizing` backend (local MLX or Claude); for short
/// transcripts it's a single direct call, identical to before.
public enum SummaryRunner {

    /// Progress callback: (completed chunk index, total chunks). Total is 0 for
    /// the single-call (short transcript) path.
    public typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    public static func run(
        transcript: String,
        title: String,
        summarizer: Summarizing,
        chunkChars: Int = 8_000,
        progress: Progress? = nil
    ) async throws -> MeetingSummary {
        let chunks = TranscriptChunker.chunks(transcript, maxChars: chunkChars)

        // Short meeting: one call, no map-reduce.
        guard chunks.count > 1 else {
            return try await summarizer.summarize(transcript: transcript, meetingTitle: title)
        }

        // Map: summarize each chunk independently (sequential → flat memory).
        var partials: [MeetingSummary] = []
        for (i, chunk) in chunks.enumerated() {
            let part = try await summarizer.summarize(
                transcript: chunk,
                meetingTitle: "\(title) — part \(i + 1) of \(chunks.count)"
            )
            partials.append(part)
            progress?(i + 1, chunks.count)
        }

        // Reduce: combine the partial summaries into one text.
        let combined = partials.enumerated().map { idx, p -> String in
            let items = p.actionItems.map { "- \($0)" }.joined(separator: "\n")
            return "Part \(idx + 1) summary: \(p.summary)\nAction items:\n\(items)"
        }.joined(separator: "\n\n")

        // If even the combined partials are too long (a very long meeting with
        // many chunks), reduce hierarchically. Partial summaries shrink the text
        // at each level, so this converges quickly.
        if combined.count > chunkChars {
            return try await run(
                transcript: combined, title: title,
                summarizer: summarizer, chunkChars: chunkChars, progress: progress
            )
        }
        return try await summarizer.summarize(transcript: combined, meetingTitle: title)
    }
}
