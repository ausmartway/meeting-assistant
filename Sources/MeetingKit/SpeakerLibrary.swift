import Foundation

/// A person the app can recognize by voice across meetings. "Me" is just the
/// known speaker with `isMe == true` (enrolled by reading a script at setup).
public struct KnownSpeaker: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String         // "Me", "Sam", …
    public var isMe: Bool
    public var embedding: [Float]    // voiceprint centroid
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, isMe: Bool, embedding: [Float], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.embedding = embedding
        self.updatedAt = updatedAt
    }
}

/// Locally-persisted set of known speakers, stored as JSON. Loaded on init
/// (empty if the file is absent or unreadable) and re-saved on every mutation.
public final class SpeakerLibrary {
    private let url: URL
    private var speakers: [KnownSpeaker]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([KnownSpeaker].self, from: data) {
            self.speakers = decoded
        } else {
            self.speakers = []
        }
    }

    public func all() -> [KnownSpeaker] { speakers }

    /// The enrolled local user, if any.
    public var me: KnownSpeaker? { speakers.first(where: { $0.isMe }) }

    /// Add a speaker, or update the voiceprint of an existing one with the same
    /// name (case-insensitive). Names are unique by case-insensitive match.
    public func upsert(name: String, embedding: [Float], isMe: Bool) throws {
        if let idx = speakers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            speakers[idx].embedding = embedding
            speakers[idx].isMe = isMe
            speakers[idx].updatedAt = Date()
        } else {
            speakers.append(KnownSpeaker(name: name, isMe: isMe, embedding: embedding))
        }
        try save()
    }

    public func rename(id: UUID, to newName: String) throws {
        guard let idx = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[idx].name = newName
        speakers[idx].updatedAt = Date()
        try save()
    }

    public func delete(id: UUID) throws {
        speakers.removeAll { $0.id == id }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(speakers)
        try data.write(to: url, options: .atomic)
    }
}
