import Foundation

/// Parses a transcript document produced by `TranscriptFormatter` back into
/// structured turns, so the reading view can render real per-turn blocks instead
/// of dumping near-raw Markdown. Pure and unit-tested. Export/Copy keep using the
/// formatter's string output; this is an additive, read-only view model.
public enum TranscriptParser {

    public struct Turn: Equatable, Sendable {
        public let time: String  // "14:53:02" or "00:05" (may be empty)
        public let speaker: String  // "Me", "Cameron Huysman", "Speaker 2"
        public let text: String
        public init(time: String, speaker: String, text: String) {
            self.time = time
            self.speaker = speaker
            self.text = text
        }
    }

    public struct Parsed: Equatable, Sendable {
        public let title: String?
        public let note: String?
        public let turns: [Turn]
        public init(title: String?, note: String?, turns: [Turn]) {
            self.title = title
            self.note = note
            self.turns = turns
        }
    }

    public static func parse(_ document: String) -> Parsed {
        var title: String?
        var note: String?
        var turns: [Turn] = []

        for raw in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let turn = parseTurn(line) {
                turns.append(turn)
                continue
            }

            if turns.isEmpty {
                // Header region: capture a `# title` and an `_note_`; ignore
                // everything else here (e.g. the ISO date line).
                if title == nil, line.hasPrefix("# ") {
                    title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                } else if note == nil, line.count >= 2, line.hasPrefix("_"), line.hasSuffix("_") {
                    note = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            // After at least one turn, a stray non-turn line continues the last
            // turn's text (defends against an embedded newline in a turn).
            let last = turns.removeLast()
            turns.append(Turn(time: last.time, speaker: last.speaker, text: last.text + " " + line))
        }

        return Parsed(title: title, note: note, turns: turns)
    }

    /// Parse `**[<time>] <speaker>:** <text>`; nil if `line` isn't a turn line.
    private static func parseTurn(_ line: String) -> Turn? {
        guard line.hasPrefix("**["),
            let closeBracket = line.range(of: "] "),
            let labelEnd = line.range(of: ":** ")
        else { return nil }
        let timeStart = line.index(line.startIndex, offsetBy: 3)
        guard timeStart <= closeBracket.lowerBound,
            closeBracket.upperBound <= labelEnd.lowerBound
        else { return nil }
        let time = String(line[timeStart..<closeBracket.lowerBound])
        let speaker = String(line[closeBracket.upperBound..<labelEnd.lowerBound])
        let text = String(line[labelEnd.upperBound...])
        return Turn(time: time, speaker: speaker, text: text)
    }
}
