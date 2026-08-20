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

    /// A shared-screen keyframe recovered from the document (R28). Kept **separate**
    /// from `turns` on purpose: `TranscriptAudioLocator` matches turns positionally
    /// against `segments.json`, so adding non-speech entries to `turns` would silently
    /// break per-line audio playback (R27).
    public struct Slide: Equatable, Sendable {
        public let time: String  // "00:00:30", as written in the document
        public let file: String  // bundle-relative, e.g. "slides/slide-00030.jpg"
        /// Index of the turn this slide follows; `-1` when it precedes all speech.
        public let afterTurnIndex: Int
        public init(time: String, file: String, afterTurnIndex: Int) {
            self.time = time
            self.file = file
            self.afterTurnIndex = afterTurnIndex
        }
    }

    public struct Parsed: Equatable, Sendable {
        public let title: String?
        public let note: String?
        public let turns: [Turn]
        public let slides: [Slide]
        public init(title: String?, note: String?, turns: [Turn], slides: [Slide] = []) {
            self.title = title
            self.note = note
            self.turns = turns
            self.slides = slides
        }
    }

    public static func parse(_ document: String) -> Parsed {
        var title: String?
        var note: String?
        var turns: [Turn] = []
        var slides: [Slide] = []

        for raw in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let turn = parseTurn(line) {
                turns.append(turn)
                continue
            }

            if let slide = parseSlide(line, afterTurnIndex: turns.count - 1) {
                slides.append(slide)
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

        return Parsed(title: title, note: note, turns: turns, slides: slides)
    }

    /// Parse `![<alt>](<path>)`; nil if `line` isn't a well-formed image line. The alt
    /// text's trailing token is the timestamp the formatter wrote
    /// ("Shared screen 00:00:30").
    private static func parseSlide(_ line: String, afterTurnIndex: Int) -> Slide? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
            let altEnd = line.range(of: "](")
        else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let path = String(line[altEnd.upperBound..<line.index(before: line.endIndex)])
        guard !path.isEmpty else { return nil }
        let time = alt.split(separator: " ").last.map(String.init) ?? ""
        return Slide(time: time, file: path, afterTurnIndex: afterTurnIndex)
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
