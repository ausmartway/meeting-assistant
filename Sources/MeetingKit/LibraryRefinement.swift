import Foundation

/// After a meeting is processed, decide which cluster voiceprints to fold into
/// the known-speaker library. A cluster qualifies only when the pipeline already
/// attributed it to a known speaker (its label matches a library name — which
/// required passing the distance, margin, and duration gates) AND its recorded
/// duration clears the trust floor here too (defense in depth: rename-edited
/// maps re-enter this path). Pure and deterministic (ordered by cluster id).
public enum LibraryRefinement {
    public struct Update: Equatable, Sendable {
        public let name: String  // the library's spelling
        public let embedding: [Float]
        public let seconds: TimeInterval

        public init(name: String, embedding: [Float], seconds: TimeInterval) {
            self.name = name
            self.embedding = embedding
            self.seconds = seconds
        }
    }

    public static func updates(
        map: MeetingSpeakerMap, known: [KnownSpeaker]
    ) -> [Update] {
        var result: [Update] = []
        for (cluster, label) in map.labelByCluster.sorted(by: { $0.key < $1.key }) {
            guard
                let speaker = known.first(where: { $0.name.lowercased() == label.lowercased() }),
                let embedding = map.embeddingByCluster[cluster], !embedding.isEmpty,
                // Intentional divergence from `MeetingSpeakerMap.learnableVoiceprint`:
                // that path treats a legacy no-duration map as learnable on an
                // explicit user rename, but auto-refinement here is stricter and
                // skips clusters with no recorded duration outright. Do not unify.
                let seconds = map.durationByCluster[cluster],
                seconds >= SpeakerRecognizer.minSpeechDuration
            else { continue }
            result.append(Update(name: speaker.name, embedding: embedding, seconds: seconds))
        }
        return result
    }
}
