import Foundation

/// Rewrites the title heading of a rendered transcript, so renaming a recording in
/// the UI keeps its saved `transcript.md` heading in sync. Pure and string-only, so
/// the rewrite is unit-testable without touching disk.
public enum TranscriptTitleEditor {
    /// Replace the document's first H1 line (`# …`) with `newTitle`. Returns the
    /// text unchanged if there is no H1 heading.
    public static func retitle(_ markdown: String, to newTitle: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) else {
            return markdown
        }
        lines[i] = "# \(newTitle)"
        return lines.joined(separator: "\n")
    }
}
