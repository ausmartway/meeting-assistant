import Testing
@testable import MeetingKit

@Suite("TranscriptChunker")
struct TranscriptChunkerTests {

    @Test("returns a single chunk when the text fits")
    func singleChunk() {
        let chunks = TranscriptChunker.chunks("one line\ntwo line", maxChars: 1000)
        #expect(chunks == ["one line\ntwo line"])
    }

    @Test("splits on line boundaries without exceeding maxChars")
    func splitsOnLines() {
        // each line is 10 chars incl. newline; maxChars 25 → ~2 lines per chunk
        let text = ["aaaaaaaaa", "bbbbbbbbb", "ccccccccc", "ddddddddd"].joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(text, maxChars: 25)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.count <= 25 })
    }

    @Test("preserves all content across chunks")
    func noContentLost() {
        let lines = (0..<50).map { "line number \($0) some words here" }
        let text = lines.joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(text, maxChars: 120)
        for line in lines {
            #expect(chunks.contains { $0.contains(line) })
        }
    }

    @Test("hard-splits a single line longer than maxChars")
    func hardSplitsLongLine() {
        let chunks = TranscriptChunker.chunks(String(repeating: "x", count: 100), maxChars: 30)
        #expect(chunks.count >= 4)
        #expect(chunks.allSatisfy { $0.count <= 30 })
    }
}
