import Foundation

/// One voice-mode centroid for a known speaker (e.g. headset vs laptop mic),
/// weighted by how much speech backs it.
public struct VoiceSample: Codable, Sendable, Equatable {
    public var embedding: [Float]
    public var seconds: TimeInterval
    public var addedAt: Date

    public init(embedding: [Float], seconds: TimeInterval, addedAt: Date = Date()) {
        self.embedding = embedding
        self.seconds = seconds
        self.addedAt = addedAt
    }
}

/// A person the app can recognize by voice across meetings. "Me" is just the
/// known speaker with `isMe == true` (enrolled by reading a script at setup).
/// The voiceprint is a small set of `samples` — one per distinct voice mode —
/// matched by nearest sample and grown from confidently-attributed clusters.
public struct KnownSpeaker: Codable, Sendable, Identifiable, Equatable {
    /// Weight given to a print that predates per-sample tracking (one
    /// enrollment's worth), so a legacy print is neither lost nor instantly
    /// outweighed by its first blend.
    public static let legacySampleSeconds: TimeInterval = 30

    public let id: UUID
    public var name: String  // "Me", "Sam", …
    public var isMe: Bool
    public var samples: [VoiceSample]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, isMe: Bool, samples: [VoiceSample],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.samples = samples
        self.updatedAt = updatedAt
    }

    /// Single-embedding convenience: one sample at the legacy weight. Keeps
    /// enrollment and existing call sites simple.
    public init(
        id: UUID = UUID(), name: String, isMe: Bool, embedding: [Float],
        updatedAt: Date = Date()
    ) {
        self.init(
            id: id, name: name, isMe: isMe,
            samples: [
                VoiceSample(
                    embedding: embedding, seconds: Self.legacySampleSeconds, addedAt: updatedAt)
            ],
            updatedAt: updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isMe, samples, embedding, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isMe = try c.decode(Bool.self, forKey: .isMe)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        if let samples = try c.decodeIfPresent([VoiceSample].self, forKey: .samples) {
            self.samples = samples
        } else {
            // Library written before multi-sample prints: one legacy-weight sample.
            let embedding = try c.decodeIfPresent([Float].self, forKey: .embedding) ?? []
            self.samples = [
                VoiceSample(
                    embedding: embedding, seconds: Self.legacySampleSeconds, addedAt: updatedAt)
            ]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isMe, forKey: .isMe)
        try c.encode(samples, forKey: .samples)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// When renaming a meeting speaker to `name`, the `isMe` flag the upsert should
    /// carry: preserve an existing known speaker's flag (case-insensitive) so
    /// renaming a cluster to "Me" can't silently demote the enrolled user and
    /// disable diarization; `false` for a brand-new name. Pure, so the rename flow's
    /// most consequential invariant is unit-testable.
    public static func preservedIsMe(forName name: String, in known: [KnownSpeaker]) -> Bool {
        known.first { $0.name.lowercased() == name.lowercased() }?.isMe ?? false
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
            let decoded = try? JSONDecoder().decode([KnownSpeaker].self, from: data)
        {
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
            speakers[idx].samples = [
                VoiceSample(embedding: embedding, seconds: KnownSpeaker.legacySampleSeconds)
            ]
            speakers[idx].isMe = isMe
            speakers[idx].updatedAt = Date()
        } else {
            speakers.append(KnownSpeaker(name: name, isMe: isMe, embedding: embedding))
        }
        try save()
    }

    /// Additively fold a trusted voice sample into `name`'s print (creating the
    /// speaker if new). Unlike `upsert` — a deliberate reset — `learn` never
    /// discards what the print already knows; growth is bounded by
    /// `VoicePrint.maxSamples` via merge-closest. `isMe` applies only when
    /// creating a new entry; learning never flips an existing speaker's flag.
    public func learn(
        name: String, embedding: [Float], seconds: TimeInterval, isMe: Bool = false
    ) throws {
        guard !embedding.isEmpty else { return }
        let sample = VoiceSample(embedding: embedding, seconds: seconds)
        if let idx = speakers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            speakers[idx].samples = VoicePrint.adding(sample, to: speakers[idx].samples)
            speakers[idx].updatedAt = Date()
        } else {
            speakers.append(KnownSpeaker(name: name, isMe: isMe, samples: [sample]))
        }
        try save()
    }

    public func rename(id: UUID, to newName: String) throws {
        guard let idx = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[idx].name = newName
        speakers[idx].updatedAt = Date()
        try save()
    }

    /// Ensure the enrolled local user (the `isMe` entry) is named `name`, renaming it
    /// if different. Preserves the voiceprint + `isMe`. No-op if already correct or if
    /// the user isn't enrolled. Used to default/migrate "Me" to the account name.
    public func setLocalUserName(_ name: String) throws {
        guard let idx = speakers.firstIndex(where: { $0.isMe }) else { return }
        guard speakers[idx].name != name else { return }
        speakers[idx].name = name
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
