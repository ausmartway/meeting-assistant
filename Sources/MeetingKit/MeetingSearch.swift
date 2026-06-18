import Foundation

/// Pure free-text search over saved recordings. The caller supplies a prebuilt
/// per-meeting "haystack" (lowercased title + date + transcript), so matching is a
/// simple substring test with no file I/O — fully unit-testable.
public enum MeetingSearch {
    /// Recordings whose haystack contains the query, preserving input order. An empty
    /// or whitespace-only query returns every recording unchanged.
    public static func filter(
        _ recordings: [MeetingRecording],
        query: String,
        haystackByID: [String: String]
    ) -> [MeetingRecording] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return recordings }
        return recordings.filter { haystackByID[$0.meeting.id]?.contains(q) == true }
    }

    /// The always-available part of a recording's haystack: its title and the date as
    /// shown in the list, lowercased. Transcript text is appended separately by the
    /// caller once it has been read from disk.
    public static func baseHaystack(for recording: MeetingRecording) -> String {
        let date = recording.recordedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(recording.meeting.title) \(date)".lowercased()
    }
}
