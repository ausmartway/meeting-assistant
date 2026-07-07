import Foundation

/// Persists captured meetings as self-contained bundles on disk and lists them
/// back for the main window. Each meeting lives in its own directory under
/// Application Support:
///
///   <AppSupport>/MeetingAssistant/<meeting-id>/
///     ├── recording.json     (MeetingRecording metadata + speaker timeline)
///     ├── mic.wav            (local user audio)
///     ├── system.wav         (remote participants audio)
///     └── transcript.md      (written after processing)
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
        try markdown.write(
            to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    /// Persist the per-meeting speaker map (cluster voiceprints + display labels)
    /// as `speakers.json`, so speakers can be renamed later without re-diarizing.
    public func saveSpeakerMap(_ map: MeetingSpeakerMap, for meetingID: String) throws {
        let url = try directory(for: meetingID).appendingPathComponent("speakers.json")
        let data = try JSONEncoder().encode(map)
        try data.write(to: url, options: .atomic)
    }

    /// Delete a meeting's per-meeting speaker map (`speakers.json`) so the next
    /// (re-)transcription re-recognizes speakers from scratch. Idempotent. Never
    /// touches the global speaker library (a root-level file, not in any bundle).
    public func deleteSpeakerMap(for meetingID: String) {
        let url = bundleURL(for: meetingID).appendingPathComponent("speakers.json")
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Load the per-meeting speaker map, if present.
    public func speakerMap(for meetingID: String) -> MeetingSpeakerMap? {
        guard let dir = try? directory(for: meetingID) else { return nil }
        let url = dir.appendingPathComponent("speakers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingSpeakerMap.self, from: data)
    }

    /// Persist the fused, labeled segments (`segments.json`) so the UI can play
    /// the exact audio clip behind each transcript line. Written on every
    /// (re-)transcription; deleted with the bundle; harmless once audio expires.
    public func saveSegments(_ segments: [LabeledSegment], for meetingID: String) throws {
        let url = try directory(for: meetingID).appendingPathComponent("segments.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(segments).write(to: url, options: .atomic)
    }

    /// The saved labeled segments, or nil for meetings transcribed before
    /// `segments.json` existed (or an unreadable file).
    public func segments(for meetingID: String) -> [LabeledSegment]? {
        let url = bundleURL(for: meetingID).appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LabeledSegment].self, from: data)
    }

    /// All saved recordings, newest first.
    public func allRecordings() -> [MeetingRecording] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let dirs = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else {
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
        let file = transcriptURL(for: meetingID)
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// On-disk location of a meeting's transcript file (may not exist yet). Used
    /// to reveal the transcript in Finder.
    public func transcriptURL(for meetingID: String) -> URL {
        root.appendingPathComponent(sanitize(meetingID)).appendingPathComponent("transcript.md")
    }

    /// Delete a meeting's entire bundle — audio, metadata, and transcript — from
    /// disk, so recordings don't accumulate forever in a folder the user can't see.
    public func delete(meetingID: String) throws {
        let dir = root.appendingPathComponent(sanitize(meetingID), isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Retention helpers

    /// Bundle directory path for a meeting WITHOUT creating it (unlike
    /// `directory(for:)`). Used by read/expiry/size helpers so they never
    /// resurrect a deleted bundle as an empty folder.
    private func bundleURL(for meetingID: String) -> URL {
        root.appendingPathComponent(sanitize(meetingID), isDirectory: true)
    }

    /// Fixed audio filenames written by `CaptureSession`.
    private static let audioFiles = ["mic.wav", "system.wav"]

    /// True iff both audio files still exist — i.e. the recording can still be
    /// re-transcribed. False once media has been expired to reclaim space.
    public func hasAudio(meetingID: String) -> Bool {
        let dir = bundleURL(for: meetingID)
        return Self.audioFiles.allSatisfy {
            fileManager.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Delete just the heavy audio (mic.wav + system.wav), keeping the transcript,
    /// metadata, and per-meeting speaker map. Idempotent: a missing file is a no-op.
    public func expireMedia(meetingID: String) {
        let dir = bundleURL(for: meetingID)
        for name in Self.audioFiles {
            let url = dir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Total bytes on disk for one meeting bundle (0 if absent).
    public func bundleSize(meetingID: String) -> Int64 {
        directorySize(bundleURL(for: meetingID))
    }

    /// Directories under the store root that hold downloaded ML models, not user
    /// recordings — never counted as "used" and never cleaned up as orphans.
    private static let modelDirNames: Set<String> = ["WhisperModels", "DiarizationModels"]

    /// Whether a directory is a real meeting bundle (has a saved `recording.json`).
    private func isMeetingBundle(_ dir: URL) -> Bool {
        fileManager.fileExists(atPath: dir.appendingPathComponent("recording.json").path)
    }

    /// Total bytes on disk for the user's data: real meeting bundles (those with a
    /// saved `recording.json`) plus root-level files like the global speaker library.
    /// This is what the "space used" view shows. It ignores the downloaded model
    /// caches (often many GB) AND orphaned capture folders — audio left behind by a
    /// session that started but never finished saving — since neither is data the
    /// user can see or manage. (Orphans are reclaimed by `deleteOrphanedBundles`.)
    public func totalSize() -> Int64 {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)  // root files (speakers.json, …)
            } else if isMeetingBundle(entry) {
                total += directorySize(entry)  // a real meeting bundle
            }
            // else: model cache or orphaned capture folder → not counted.
        }
        return total
    }

    /// Reclaim orphaned capture folders: directories that hold audio but never got a
    /// `recording.json` (a capture that started but never finished saving — e.g. a
    /// crash or force-quit). They're invisible in the UI and the retention sweep
    /// skips them, so they'd leak disk forever. The model caches and any
    /// currently-active meeting (in `activeIDs`) are never touched. Returns the bytes
    /// reclaimed.
    @discardableResult
    public func deleteOrphanedBundles(activeIDs: Set<String> = []) -> Int64 {
        let activeDirNames = Set(activeIDs.map(sanitize))
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return 0 }
        var reclaimed: Int64 = 0
        for entry in entries {
            let name = entry.lastPathComponent
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir, !Self.modelDirNames.contains(name), !activeDirNames.contains(name),
                !isMeetingBundle(entry)
            else { continue }
            reclaimed += directorySize(entry)
            try? fileManager.removeItem(at: entry)
        }
        return reclaimed
    }

    /// Recursively sum the byte size of regular files under `url`.
    private func directorySize(_ url: URL) -> Int64 {
        guard
            let en = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Apply a retention policy across every meeting bundle. Bundle deletion
    /// (transcript window) takes precedence over media expiry. Skips any meeting in
    /// `activeIDs` (recording or transcribing now). Operates ONLY on directories
    /// that contain a `recording.json`, so the root-level global `speakers.json`
    /// (the cross-meeting voiceprint library) is structurally never touched.
    public func sweep(policy: RetentionPolicy, now: Date, activeIDs: Set<String>)
        -> RetentionSweepResult
    {
        var result = RetentionSweepResult()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let dirs = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )
        else { return result }

        for dir in dirs {
            // Only valid meeting bundles — a directory with a decodable recording.json.
            let recordingJSON = dir.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: recordingJSON),
                let rec = try? decoder.decode(MeetingRecording.self, from: data)
            else { continue }
            let id = rec.meeting.id
            guard !activeIDs.contains(id) else { continue }

            if policy.shouldDeleteBundle(recordedAt: rec.recordedAt, now: now) {
                let size = directorySize(dir)
                try? fileManager.removeItem(at: dir)
                result.bundlesDeleted += 1
                result.bytesReclaimed += size
            } else if policy.shouldExpireMedia(recordedAt: rec.recordedAt, now: now) {
                let before = directorySize(dir)
                expireMedia(meetingID: id)
                let reclaimed = before - directorySize(dir)
                if reclaimed > 0 {
                    result.mediaExpired += 1
                    result.bytesReclaimed += reclaimed
                }
            }
        }
        return result
    }

    // MARK: - Private utilities

    /// Keep meeting ids filesystem-safe (EKEvent identifiers can contain slashes).
    private func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
