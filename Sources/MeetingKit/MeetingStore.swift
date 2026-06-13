import Foundation

/// Persists captured meetings as self-contained bundles on disk and lists them
/// back for the main window. Each meeting lives in its own directory under
/// Application Support:
///
///   <AppSupport>/MeetingAssistant/<meeting-id>/
///     ├── recording.json     (MeetingRecording metadata + speaker timeline)
///     ├── mic.wav            (local user audio)
///     ├── system.wav         (remote participants audio)
///     ├── transcript.md      (written after processing)
///     └── summary.md         (written after processing)
public final class MeetingStore {
    private let root: URL
    private let fileManager: FileManager

    /// `root` defaults to Application Support; injectable for tests.
    public init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.root = appSupport.appendingPathComponent("MeetingAssistant", isDirectory: true)
        }
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// The directory for a given meeting, created on demand.
    public func directory(for meetingID: String) throws -> URL {
        let dir = root.appendingPathComponent(sanitize(meetingID), isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Persist the recording metadata for a meeting.
    public func save(_ recording: MeetingRecording) throws {
        let dir = try directory(for: recording.meeting.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recording)
        try data.write(to: dir.appendingPathComponent("recording.json"))
    }

    /// Write the speaker-labeled transcript markdown.
    public func saveTranscript(_ markdown: String, for meetingID: String) throws {
        let dir = try directory(for: meetingID)
        try markdown.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    /// Write the summary markdown.
    public func saveSummary(_ markdown: String, for meetingID: String) throws {
        let dir = try directory(for: meetingID)
        try markdown.write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    /// All saved recordings, newest first.
    public func allRecordings() -> [MeetingRecording] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return dirs.compactMap { dir -> MeetingRecording? in
            let file = dir.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(MeetingRecording.self, from: data)
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Load the transcript markdown for a meeting, if present.
    public func transcript(for meetingID: String) -> String? {
        let file = root.appendingPathComponent(sanitize(meetingID)).appendingPathComponent("transcript.md")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Load the summary markdown for a meeting, if present.
    public func summary(for meetingID: String) -> String? {
        let file = root.appendingPathComponent(sanitize(meetingID)).appendingPathComponent("summary.md")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Keep meeting ids filesystem-safe (EKEvent identifiers can contain slashes).
    private func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
