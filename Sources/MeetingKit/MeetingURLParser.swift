import Foundation

/// Extracts a video-conferencing join link and its provider from the fields of a
/// calendar event. EventKit has no dedicated "conference URL" field, so we scan
/// `url`, `notes`, and `location` (in that priority order) for a known provider
/// pattern — the same heuristic Apple's own "join with one tap" uses.
public enum MeetingURLParser {

    /// A recognized meeting link.
    public struct MeetingLink: Equatable, Sendable {
        public let provider: MeetingProvider
        public let url: URL
    }

    /// Parse the relevant fields of an event. Returns the first recognized meeting
    /// link, preferring the dedicated `url` field, then `notes`, then `location`.
    public static func parse(url: URL?, notes: String?, location: String?) -> MeetingLink? {
        // 1. A dedicated url field is the most reliable — but only if it is itself
        //    a meeting link (calendars sometimes put an agenda link here instead).
        if let url, let link = classify(url) {
            return link
        }
        // 2. The join link most often lives in the notes body.
        if let notes, let link = firstLink(in: notes) {
            return link
        }
        // 3. Finally, some providers stash the URL in the location field.
        if let location, let link = firstLink(in: location) {
            return link
        }
        return nil
    }

    // MARK: - Internals

    /// Classify a single URL by matching its string against known provider patterns.
    private static func classify(_ url: URL) -> MeetingLink? {
        let s = url.absoluteString
        for provider in MeetingProvider.allCases where matches(s, provider) {
            return MeetingLink(provider: provider, url: url)
        }
        return nil
    }

    /// Find the first recognized meeting link within an arbitrary block of text.
    private static func firstLink(in text: String) -> MeetingLink? {
        for raw in extractURLStrings(from: text) {
            guard let url = URL(string: raw) else { continue }
            if let link = classify(url) { return link }
        }
        return nil
    }

    /// Pull every `http(s)://…` token out of free-form text, trimming trailing
    /// punctuation that commonly clings to a URL in prose.
    private static func extractURLStrings(from text: String) -> [String] {
        let pattern = #"https?://[^\s<>"')]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        }
    }

    /// Per-provider substring tests against a URL string.
    private static func matches(_ s: String, _ provider: MeetingProvider) -> Bool {
        switch provider {
        case .zoom:
            // e.g. https://us02web.zoom.us/j/8412345678 — host contains zoom.us
            // and there is a meeting path segment.
            return s.contains("zoom.us/") &&
                (s.contains("/j/") || s.contains("/w/") || s.contains("/s/") || s.contains("/my/"))
        case .googleMeet:
            return s.contains("meet.google.com/")
        case .microsoftTeams:
            return s.contains("teams.microsoft.com/l/meetup-join") ||
                s.contains("teams.live.com/meet")
        case .webex:
            // e.g. https://acme.webex.com/acme/j.php?MTID=… or …/meet/<name>.
            // The host (…webex.com/) is the reliable signal across Webex link forms.
            return s.contains("webex.com/")
        }
    }
}
