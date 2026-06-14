import Testing
@testable import MeetingKit

/// Records how many times it's asked to summarize, so we can assert map-reduce.
private actor FakeSummarizer: Summarizing {
    private(set) var callCount = 0
    private(set) var inputs: [String] = []

    func summarize(transcript: String, meetingTitle: String) async throws -> MeetingSummary {
        callCount += 1
        inputs.append(transcript)
        return MeetingSummary(summary: "summary#\(callCount)", actionItems: ["item#\(callCount)"])
    }
    func count() -> Int { callCount }
}

@Suite("SummaryRunner")
struct SummaryRunnerTests {

    @Test("short transcript is summarized in a single call")
    func singleCall() async throws {
        let fake = FakeSummarizer()
        _ = try await SummaryRunner.run(transcript: "short body", title: "T", summarizer: fake, chunkChars: 1000)
        let n = await fake.count()
        #expect(n == 1)
    }

    @Test("long transcript is mapped per chunk then reduced (>=3 calls)")
    func mapReduce() async throws {
        let fake = FakeSummarizer()
        let long = (0..<100).map { "Line \($0) with some content here" }.joined(separator: "\n")
        let result = try await SummaryRunner.run(transcript: long, title: "T", summarizer: fake, chunkChars: 200)
        let n = await fake.count()
        #expect(n >= 3)                       // multiple chunk summaries + one reduce
        #expect(!result.summary.isEmpty)      // returns the reduced summary
    }
}
