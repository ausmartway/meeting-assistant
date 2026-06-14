import Foundation

/// Splits a transcript into chunks no larger than `maxChars`, breaking on line
/// boundaries so a speaker turn is kept whole where possible. Used to feed a long
/// meeting through the local LLM in bounded pieces (map-reduce summarization),
/// keeping memory flat on a 16 GB machine regardless of meeting length.
public enum TranscriptChunker {

    public static func chunks(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            // A single over-long line: flush, then hard-split it.
            if line.count > maxChars {
                flush()
                chunks.append(contentsOf: hardSplit(line, maxChars: maxChars))
                continue
            }
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > maxChars {
                flush()
                current = line
            } else {
                current = candidate
            }
        }
        flush()
        return chunks
    }

    /// Break a single string into pieces of at most `maxChars` characters.
    private static func hardSplit(_ s: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: maxChars, limitedBy: s.endIndex) ?? s.endIndex
            pieces.append(String(s[idx..<end]))
            idx = end
        }
        return pieces
    }
}
