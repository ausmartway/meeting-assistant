import Testing
@testable import MeetingKit

@Suite("SummarizationPrompt")
struct SummarizationPromptTests {

    @Test("parses a clean JSON object into a summary")
    func parsesCleanJSON() {
        let raw = #"{"summary": "We agreed on the Q3 plan.", "actionItems": ["Alice drafts spec", "Bob reviews budget"]}"#
        let result = SummarizationPrompt.parse(raw)
        #expect(result.summary == "We agreed on the Q3 plan.")
        #expect(result.actionItems == ["Alice drafts spec", "Bob reviews budget"])
    }

    @Test("parses JSON wrapped in a markdown code fence")
    func parsesFencedJSON() {
        let raw = """
        Here is the result:
        ```json
        {"summary": "Short sync.", "actionItems": ["Ship the build"]}
        ```
        """
        let result = SummarizationPrompt.parse(raw)
        #expect(result.summary == "Short sync.")
        #expect(result.actionItems == ["Ship the build"])
    }

    @Test("falls back to raw text as the summary when no JSON is present")
    func fallsBackToRawText() {
        let raw = "The team discussed onboarding and nothing else."
        let result = SummarizationPrompt.parse(raw)
        #expect(result.summary == "The team discussed onboarding and nothing else.")
        #expect(result.actionItems.isEmpty)
    }

    @Test("the built prompt contains the transcript and asks for JSON")
    func buildsPrompt() {
        let prompt = SummarizationPrompt.build(transcript: "Alice: hello", title: "Standup")
        #expect(prompt.contains("Alice: hello"))
        #expect(prompt.contains("Standup"))
        #expect(prompt.lowercased().contains("json"))
    }
}
