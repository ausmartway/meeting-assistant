import Foundation

/// Summarizes a transcript via the Claude API (raw HTTPS over URLSession — there
/// is no official Anthropic SDK for Swift). This is the opt-in "re-summarize with
/// Claude" path for important meetings; the local LLM remains the private default.
///
/// The transcript text leaves the machine when this is used; audio never does.
public struct ClaudeSummarizer: Summarizing {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    /// Default model per the Anthropic guidance is the most capable Opus tier.
    /// Selectable in Settings (e.g. switch to `claude-haiku-4-5` for lower cost).
    public init(
        apiKey: String,
        model: String = "claude-opus-4-8",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func summarize(transcript: String, meetingTitle: String) async throws -> MeetingSummary {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                ["role": "user", "content": SummarizationPrompt.build(transcript: transcript, title: meetingTitle)]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw ClaudeError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: detail)
        }

        // Response shape: { "content": [ { "type": "text", "text": "..." }, ... ] }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            throw ClaudeError.unexpectedResponse
        }

        return SummarizationPrompt.parse(text)
    }

    public enum ClaudeError: Error, LocalizedError {
        case httpError(status: Int, body: String)
        case unexpectedResponse

        public var errorDescription: String? {
            switch self {
            case .httpError(let status, let body):
                return "Claude API error (HTTP \(status)): \(body)"
            case .unexpectedResponse:
                return "Unexpected response shape from Claude API."
            }
        }
    }
}
