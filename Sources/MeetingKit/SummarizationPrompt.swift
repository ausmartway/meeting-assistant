import Foundation

/// Builds the summarization prompt and parses the model's reply. Kept separate
/// from any specific LLM backend so both the local (MLX) and Claude summarizers
/// share identical prompting/parsing — and so the parsing is unit-testable.
public enum SummarizationPrompt {

    /// Construct the instruction prompt for a transcript. Very long transcripts
    /// are truncated (keeping the head and tail) so the local model's context /
    /// memory stays bounded — an unbounded prompt can OOM-kill the app.
    public static func build(
        transcript: String,
        title: String,
        maxTranscriptChars: Int = 24_000
    ) -> String {
        let body = truncate(transcript, max: maxTranscriptChars)
        return """
        You are summarizing the meeting titled "\(title)".

        Read the transcript below and respond with ONLY a JSON object of the form:
        {"summary": "<2-4 sentence summary>", "actionItems": ["<owner: task>", ...]}

        Do not include any text outside the JSON. The summary and action items
        should be written in the same language as the transcript.

        Transcript:
        \(body)
        """
    }

    /// Keep the beginning (context) and the end (decisions / action items) when a
    /// transcript exceeds `max`, dropping the middle.
    static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        let headCount = Int(Double(max) * 0.6)
        let tailCount = max - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        return "\(head)\n\n[… transcript truncated for length …]\n\n\(tail)"
    }

    /// Parse a model reply into a `MeetingSummary`. Tolerates a markdown code
    /// fence around the JSON, and falls back to treating the whole reply as the
    /// summary if no valid JSON object is found.
    public static func parse(_ raw: String) -> MeetingSummary {
        if let json = extractJSONObject(from: raw),
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let summary = (obj["summary"] as? String) ?? ""
            let items = (obj["actionItems"] as? [String]) ?? []
            if !summary.isEmpty {
                return MeetingSummary(summary: summary, actionItems: items)
            }
        }
        // No usable JSON — treat the reply text as the summary.
        return MeetingSummary(
            summary: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            actionItems: []
        )
    }

    /// Pull the first balanced `{ … }` block out of arbitrary text.
    private static func extractJSONObject(from text: String) -> String? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close else { return nil }
        return String(text[open...close])
    }
}
