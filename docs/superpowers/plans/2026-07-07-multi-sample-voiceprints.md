# Multi-Sample Self-Improving Voiceprints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Known speakers hold up to 8 duration-weighted voice samples that grow from every confidently-attributed cluster, so recognition improves the more the app hears someone.

**Architecture:** `KnownSpeaker.embedding` becomes `samples: [VoiceSample]` (legacy JSON migrates on decode). Matching takes the min cosine distance over samples. Learning appends samples (merge-closest-pair at the cap) from two trusted feeds: explicit renames and post-meeting auto-refinement of clusters that already passed the distance/margin/duration gates.

**Tech Stack:** Swift 5 / SwiftPM, swift-testing (`@Suite`/`@Test`/`#expect`), macOS 14 target. Spec: `docs/superpowers/specs/2026-07-07-self-improving-voiceprints-design.md`.

## Global Constraints

- Pure logic lives in `Sources/MeetingKit/`, unit-tested first (TDD); `AppState` wiring stays thin and untested (project convention).
- Sample cap: **8** per speaker. Legacy migration weight: **30 s**. Trust floor: reuse `SpeakerRecognizer.minSpeechDuration` (15 s) — do not introduce a second constant.
- `SpeakerLibrary.upsert` keeps replace-all semantics (deliberate reset); `learn` is the only additive path.
- Run tests with `swift test --filter <SuiteName>` per task and the full `swift test` before the final commit.
- Commit format: `feat: …` / `test: …`, ending with the two `Co-Authored-By:`/`Claude-Session:` trailers used by this session (write the message to the scratchpad and `git commit -F` — heredocs are blocked by a hook).

---

### Task 1: `VoiceSample` + `KnownSpeaker.samples` with legacy decode

**Files:**
- Modify: `Sources/MeetingKit/SpeakerLibrary.swift:1-30` (KnownSpeaker)
- Test: `Tests/MeetingKitTests/VoiceSampleTests.swift` (create)

**Interfaces:**
- Produces: `struct VoiceSample { var embedding: [Float]; var seconds: TimeInterval; var addedAt: Date }` (Codable/Sendable/Equatable); `KnownSpeaker.samples: [VoiceSample]`; convenience `KnownSpeaker(id:name:isMe:embedding:updatedAt:)` builds one 30 s sample (keeps every existing call site compiling); legacy JSON with only `embedding` decodes to one 30 s sample.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("VoiceSample / KnownSpeaker migration")
struct VoiceSampleTests {

    @Test("embedding convenience init becomes a single 30s sample")
    func convenienceInit() {
        let s = KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0])
        #expect(s.samples.count == 1)
        #expect(s.samples[0].embedding == [1, 0, 0])
        #expect(s.samples[0].seconds == 30)
    }

    @Test("legacy JSON (single embedding, no samples) migrates on decode")
    func legacyDecode() throws {
        let legacy = """
            [{"id": "8B29A9F5-97A2-4B47-8A9B-4D9E27E5B111", "name": "Sam",
              "isMe": false, "embedding": [1, 0, 0],
              "updatedAt": 700000000}]
            """
        let decoded = try JSONDecoder().decode([KnownSpeaker].self, from: Data(legacy.utf8))
        #expect(decoded[0].samples.count == 1)
        #expect(decoded[0].samples[0].embedding == [1, 0, 0])
        #expect(decoded[0].samples[0].seconds == 30)
    }

    @Test("current format round-trips with multiple samples")
    func roundTrip() throws {
        var speaker = KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0])
        speaker.samples.append(
            VoiceSample(embedding: [0, 1, 0], seconds: 120, addedAt: Date(timeIntervalSince1970: 1)))
        let data = try JSONEncoder().encode([speaker])
        let decoded = try JSONDecoder().decode([KnownSpeaker].self, from: data)
        #expect(decoded[0].samples == speaker.samples)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VoiceSampleTests`
Expected: compile FAILs — `VoiceSample` undefined, `samples` not a member.

- [ ] **Step 3: Implement**

Replace the `KnownSpeaker` struct at the top of `Sources/MeetingKit/SpeakerLibrary.swift` (keep `preservedIsMe` as-is inside it):

```swift
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

    /// (keep the existing preservedIsMe(forName:in:) here unchanged)
}
```

Note: `SpeakerRecognizer.bestMatch` still references `$0.embedding` and will now fail to compile — fix it in the same step with the temporary bridge below (Task 3 replaces it properly):

```swift
// In SpeakerRecognizer.bestMatch, replace
//   (name: $0.name, distance: VoiceMatch.cosineDistance(embedding, $0.embedding))
// with:
    (name: $0.name,
     distance: $0.samples.map { VoiceMatch.cosineDistance(embedding, $0.embedding) }
        .min() ?? .infinity)
```

Also in `SpeakerLibrary.upsert`, replace `speakers[idx].embedding = embedding` with:

```swift
speakers[idx].samples = [
    VoiceSample(embedding: embedding, seconds: KnownSpeaker.legacySampleSeconds)
]
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter VoiceSampleTests` → PASS, then `swift test` → all suites PASS (the recognizer bridge keeps behavior identical for single-sample speakers).

- [ ] **Step 5: Commit** — `feat: multi-sample voiceprints data model with legacy migration`

---

### Task 2: `VoicePrint` — min-distance matching and capped sample growth

**Files:**
- Create: `Sources/MeetingKit/VoicePrint.swift`
- Test: `Tests/MeetingKitTests/VoicePrintTests.swift` (create)

**Interfaces:**
- Consumes: `VoiceSample` (Task 1), `VoiceMatch.cosineDistance` (existing).
- Produces: `VoicePrint.maxSamples: Int = 8`; `VoicePrint.distance(_ embedding: [Float], to samples: [VoiceSample]) -> Float`; `VoicePrint.adding(_ sample: VoiceSample, to samples: [VoiceSample], cap: Int = VoicePrint.maxSamples) -> [VoiceSample]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("VoicePrint")
struct VoicePrintTests {
    private func sample(_ e: [Float], seconds: TimeInterval = 60) -> VoiceSample {
        VoiceSample(embedding: e, seconds: seconds, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("distance is the minimum over samples")
    func minDistance() {
        let samples = [sample([1, 0, 0]), sample([0, 1, 0])]
        // Exactly matches the second sample → distance 0, not the average.
        #expect(VoicePrint.distance([0, 1, 0], to: samples) == 0)
    }

    @Test("distance to no samples is infinity (cannot match)")
    func emptySamples() {
        #expect(VoicePrint.distance([1, 0, 0], to: []) == .infinity)
    }

    @Test("adding below the cap appends")
    func addAppends() {
        let out = VoicePrint.adding(sample([0, 1, 0]), to: [sample([1, 0, 0])])
        #expect(out.count == 2)
    }

    @Test("adding at the cap merges the closest pair, preserving diversity")
    func addMergesClosest() {
        // Two near-identical "headset" samples + one distinct "room" sample, cap 3.
        let headsetA = sample([1, 0, 0], seconds: 60)
        let headsetB = sample([0.99, 0.14, 0], seconds: 30)  // ~0.01 from headsetA
        let room = sample([0, 0, 1], seconds: 60)
        let incoming = sample([0, 1, 0], seconds: 60)  // far from all
        let out = VoicePrint.adding(incoming, to: [headsetA, headsetB, room], cap: 3)
        #expect(out.count == 3)
        // The room and incoming samples survive untouched; the two headset
        // samples merged into one.
        #expect(out.contains(room))
        #expect(out.contains(incoming))
        #expect(!out.contains(headsetA) && !out.contains(headsetB))
    }

    @Test("merged sample is duration-weighted and accumulates seconds")
    func mergeWeights() {
        // Cap 1: incoming must merge with the only existing sample.
        let old = sample([1, 0, 0], seconds: 90)
        let new = sample([0, 1, 0], seconds: 30)
        let out = VoicePrint.adding(new, to: [old], cap: 1)
        #expect(out.count == 1)
        #expect(out[0].seconds == 120)
        // 90:30 weighting → (0.75, 0.25, 0).
        #expect(abs(out[0].embedding[0] - 0.75) < 0.001)
        #expect(abs(out[0].embedding[1] - 0.25) < 0.001)
    }

    @Test("unusable incoming embeddings are ignored")
    func unusableIgnored() {
        let existing = [sample([1, 0, 0])]
        #expect(VoicePrint.adding(sample([], seconds: 60), to: existing) == existing)
        #expect(VoicePrint.adding(sample([0, 0, 0], seconds: 60), to: existing) == existing)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter VoicePrintTests` → compile FAIL (`VoicePrint` undefined).

- [ ] **Step 3: Implement** — create `Sources/MeetingKit/VoicePrint.swift`:

```swift
import Foundation

/// Pure operations on a known speaker's set of voice samples: nearest-sample
/// matching and bounded growth. A speaker's print improves as trusted samples
/// arrive; the cap keeps storage and matching cost constant while merge-closest
/// preserves distinct voice modes (headset vs laptop mic vs meeting room).
public enum VoicePrint {
    /// Bound on samples per speaker. Merging (not dropping) at the cap means a
    /// rare-but-real voice mode survives a string of one-off meetings.
    public static let maxSamples = 8

    /// Cosine distance from `embedding` to the *nearest* sample — a person
    /// matches whichever version of their voice is closest. `.infinity` when
    /// there is nothing usable to match against.
    public static func distance(_ embedding: [Float], to samples: [VoiceSample]) -> Float {
        samples.map { VoiceMatch.cosineDistance(embedding, $0.embedding) }.min() ?? .infinity
    }

    /// Add a trusted sample: append below `cap`; at the cap, merge the closest
    /// pair among existing + incoming (duration-weighted) so diversity is kept.
    /// Unusable incoming embeddings (empty / zero-magnitude / length-mismatched
    /// with every existing sample) leave `samples` unchanged.
    public static func adding(
        _ sample: VoiceSample, to samples: [VoiceSample], cap: Int = maxSamples
    ) -> [VoiceSample] {
        guard samples.isEmpty
            || samples.contains(where: {
                VoiceMatch.cosineDistance(sample.embedding, $0.embedding) != .infinity
            })
        else { return samples }
        var all = samples + [sample]
        guard all.count > cap else { return all }
        // Merge the closest pair (there is exactly one over-cap sample).
        var bestPair = (0, 1)
        var bestDistance = Float.infinity
        for i in all.indices {
            for j in all.indices where j > i {
                let d = VoiceMatch.cosineDistance(all[i].embedding, all[j].embedding)
                if d < bestDistance {
                    bestDistance = d
                    bestPair = (i, j)
                }
            }
        }
        let merged = merge(all[bestPair.0], all[bestPair.1])
        all.remove(at: bestPair.1)  // higher index first
        all[bestPair.0] = merged
        return all
    }

    /// Duration-weighted element-wise average; seconds accumulate. Weights are
    /// floored at 1 s so a zero-duration sample can't produce NaNs.
    private static func merge(_ a: VoiceSample, _ b: VoiceSample) -> VoiceSample {
        let wa = Float(max(a.seconds, 1)), wb = Float(max(b.seconds, 1))
        let embedding = zip(a.embedding, b.embedding).map { ($0 * wa + $1 * wb) / (wa + wb) }
        return VoiceSample(
            embedding: embedding, seconds: a.seconds + b.seconds,
            addedAt: max(a.addedAt, b.addedAt))
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter VoicePrintTests` → PASS.

- [ ] **Step 5: Commit** — `feat: VoicePrint min-distance matching and capped merge-closest growth`

---

### Task 3: `SpeakerRecognizer` matches via `VoicePrint.distance`

**Files:**
- Modify: `Sources/MeetingKit/SpeakerRecognizer.swift` (`bestMatch`)
- Test: `Tests/MeetingKitTests/SpeakerRecognizerTests.swift` (append one test)

**Interfaces:**
- Consumes: `VoicePrint.distance` (Task 2).
- Produces: unchanged `resolve(...)` signature; matching now honors every sample.

- [ ] **Step 1: Write the failing test** (append to `SpeakerRecognizerTests`):

```swift
    @Test("a speaker matches on any of their samples, not just the first")
    func multiSampleMatch() {
        var sam = KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0])
        sam.samples.append(VoiceSample(embedding: [0, 1, 0], seconds: 60))
        let labels = SpeakerRecognizer.resolve(
            outcome: outcome([("c0", [0, 1, 0])]),  // matches Sam's SECOND sample
            knownSpeakers: [sam], threshold: 0.3)
        #expect(labels["c0"] == "Sam")
    }
```

- [ ] **Step 2: Run to verify state** — `swift test --filter SpeakerRecognizerTests`. Expected: PASS already if Task 1's bridge is in place (it computes min over samples). This test locks the behavior; proceed to Step 3 to formalize the implementation.

- [ ] **Step 3: Replace the bridge with the named API** — in `bestMatch`:

```swift
        let scored = known.map {
            (name: $0.name, distance: VoicePrint.distance(embedding, to: $0.samples))
        }
```

- [ ] **Step 4: Run tests** — `swift test --filter SpeakerRecognizer` → all PASS.

- [ ] **Step 5: Commit** — `feat: recognizer matches against all voice samples`

---

### Task 4: `SpeakerLibrary.learn` (additive) + `MeetingSpeakerMap.duration(forLabel:)`

**Files:**
- Modify: `Sources/MeetingKit/SpeakerLibrary.swift` (add `learn`)
- Modify: `Sources/MeetingKit/Models.swift` (add `duration(forLabel:)` next to `learnableVoiceprint`)
- Test: `Tests/MeetingKitTests/SpeakerLibraryLearnTests.swift` (create)

**Interfaces:**
- Consumes: `VoicePrint.adding` (Task 2).
- Produces: `SpeakerLibrary.learn(name: String, embedding: [Float], seconds: TimeInterval, isMe: Bool = false) throws` — appends a sample to the case-insensitive name match, creates the entry if new (with `isMe`); `MeetingSpeakerMap.duration(forLabel label: String) -> TimeInterval?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("SpeakerLibrary.learn")
struct SpeakerLibraryLearnTests {
    private func makeLibrary() throws -> (SpeakerLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("learn-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("speakers.json")
        return (SpeakerLibrary(url: url), url)
    }

    @Test("learn appends a sample to an existing speaker (case-insensitive)")
    func learnAppends() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.learn(name: "sam", embedding: [0, 1, 0], seconds: 120)
        let sam = lib.all().first { $0.name == "Sam" }
        #expect(sam?.samples.count == 2)
        #expect(sam?.samples.last?.seconds == 120)
        #expect(sam?.isMe == false)
    }

    @Test("learn creates a new speaker when the name is unknown")
    func learnCreates() throws {
        let (lib, _) = try makeLibrary()
        try lib.learn(name: "New Person", embedding: [0, 1, 0], seconds: 60)
        #expect(lib.all().first?.name == "New Person")
        #expect(lib.all().first?.samples.count == 1)
    }

    @Test("learn never flips isMe on an existing speaker")
    func learnPreservesIsMe() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Yulei", embedding: [1, 0, 0], isMe: true)
        try lib.learn(name: "Yulei", embedding: [0, 1, 0], seconds: 60, isMe: false)
        #expect(lib.me?.name == "Yulei")
    }

    @Test("learn with an empty embedding is a no-op")
    func learnIgnoresEmpty() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.learn(name: "Sam", embedding: [], seconds: 60)
        #expect(lib.all().first?.samples.count == 1)
    }

    @Test("upsert still replaces all samples (deliberate reset)")
    func upsertResets() throws {
        let (lib, _) = try makeLibrary()
        try lib.upsert(name: "Sam", embedding: [1, 0, 0], isMe: false)
        try lib.learn(name: "Sam", embedding: [0, 1, 0], seconds: 120)
        try lib.upsert(name: "Sam", embedding: [0, 0, 1], isMe: false)
        #expect(lib.all().first?.samples.count == 1)
        #expect(lib.all().first?.samples.first?.embedding == [0, 0, 1])
    }
}

@Suite("MeetingSpeakerMap.duration(forLabel:)")
struct MeetingSpeakerMapDurationTests {
    @Test("returns the cluster's recorded duration by its current label")
    func durationLookup() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam"],
            embeddingByCluster: ["c1": [0, 1, 0]],
            durationByCluster: ["c1": 42])
        #expect(map.duration(forLabel: "Sam") == 42)
        #expect(map.duration(forLabel: "Nobody") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SpeakerLibraryLearnTests` → compile FAIL (`learn` undefined).

- [ ] **Step 3: Implement**

In `SpeakerLibrary` (after `upsert`):

```swift
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
```

In `Models.swift`, next to `learnableVoiceprint`:

```swift
    /// Seconds of speech behind the cluster currently labeled `label`, or nil
    /// for unknown labels / maps saved before durations were recorded.
    public func duration(forLabel label: String) -> TimeInterval? {
        guard let cluster = labelByCluster.first(where: { $0.value == label })?.key else {
            return nil
        }
        return durationByCluster[cluster]
    }
```

- [ ] **Step 4: Run tests** — `swift test --filter "SpeakerLibraryLearnTests|MeetingSpeakerMapDurationTests"` → PASS.

- [ ] **Step 5: Commit** — `feat: additive SpeakerLibrary.learn and per-label duration lookup`

---

### Task 5: `LibraryRefinement` — post-meeting auto-fold list

**Files:**
- Create: `Sources/MeetingKit/LibraryRefinement.swift`
- Test: `Tests/MeetingKitTests/LibraryRefinementTests.swift` (create)

**Interfaces:**
- Consumes: `MeetingSpeakerMap` (labels/embeddings/durations), `KnownSpeaker`, `SpeakerRecognizer.minSpeechDuration`.
- Produces: `LibraryRefinement.updates(map: MeetingSpeakerMap, known: [KnownSpeaker]) -> [LibraryRefinement.Update]` with `struct Update: Equatable { let name: String; let embedding: [Float]; let seconds: TimeInterval }`, deterministic order (by cluster id).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import MeetingKit

@Suite("LibraryRefinement")
struct LibraryRefinementTests {
    private let known = [
        KnownSpeaker(name: "Sam", isMe: false, embedding: [1, 0, 0]),
        KnownSpeaker(name: "Yulei", isMe: true, embedding: [0, 1, 0]),
    ]

    @Test("confidently-labeled clusters produce updates; anonymous ones don't")
    func matchedClustersOnly() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam", "c2": "Speaker 2", "sys:S1": "Yulei"],
            embeddingByCluster: ["c1": [1, 0, 0], "c2": [0, 0, 1], "sys:S1": [0, 1, 0]],
            durationByCluster: ["c1": 60, "c2": 60, "sys:S1": 90])
        let updates = LibraryRefinement.updates(map: map, known: known)
        #expect(updates.count == 2)
        #expect(updates[0] == .init(name: "Sam", embedding: [1, 0, 0], seconds: 60))
        #expect(updates[1] == .init(name: "Yulei", embedding: [0, 1, 0], seconds: 90))
    }

    @Test("label matching is case-insensitive, using the library's spelling")
    func caseInsensitive() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "sam"],
            embeddingByCluster: ["c1": [1, 0, 0]],
            durationByCluster: ["c1": 60])
        #expect(LibraryRefinement.updates(map: map, known: known).first?.name == "Sam")
    }

    @Test("clusters under the trust floor or without recorded durations are skipped")
    func gatesEnforced() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam", "c2": "Yulei"],
            embeddingByCluster: ["c1": [1, 0, 0], "c2": [0, 1, 0]],
            durationByCluster: ["c1": 5])  // c1 too short; c2 legacy (no duration)
        #expect(LibraryRefinement.updates(map: map, known: known).isEmpty)
    }

    @Test("clusters with missing embeddings are skipped")
    func missingEmbedding() {
        let map = MeetingSpeakerMap(
            labelByCluster: ["c1": "Sam"],
            embeddingByCluster: [:],
            durationByCluster: ["c1": 60])
        #expect(LibraryRefinement.updates(map: map, known: known).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter LibraryRefinementTests` → compile FAIL.

- [ ] **Step 3: Implement** — create `Sources/MeetingKit/LibraryRefinement.swift`:

```swift
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
                let seconds = map.durationByCluster[cluster],
                seconds >= SpeakerRecognizer.minSpeechDuration
            else { continue }
            result.append(Update(name: speaker.name, embedding: embedding, seconds: seconds))
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter LibraryRefinementTests` → PASS.

- [ ] **Step 5: Commit** — `feat: LibraryRefinement picks trusted clusters to auto-learn`

---

### Task 6: AppState wiring — auto-refine after processing, learn on rename

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift` (two spots: after `processor.process` succeeds ~line 469; inside `renameSpeaker` ~line 550)

**Interfaces:**
- Consumes: `LibraryRefinement.updates`, `SpeakerLibrary.learn`, `MeetingSpeakerMap.duration(forLabel:)`, `learnableVoiceprint` (existing).

- [ ] **Step 1: Auto-refinement after processing** — in the `do` block where processing succeeds, immediately after `_ = try await processor.process(recording, progress: progress)` and before `postNotification`:

```swift
            // Self-improving prints: fold every confidently-attributed cluster of
            // this meeting back into the library, so recognition gets better the
            // more the app hears each person. LibraryRefinement re-checks the
            // trust gates; anonymous "Speaker N" clusters never qualify.
            if let map = store.speakerMap(for: recording.meeting.id) {
                for update in LibraryRefinement.updates(
                    map: map, known: settings.speakerLibrary.all())
                {
                    try? settings.speakerLibrary.learn(
                        name: update.name, embedding: update.embedding,
                        seconds: update.seconds)
                }
            }
```

- [ ] **Step 2: Rename learns additively** — in `renameSpeaker`, replace the `upsert` call inside `if let embedding = learnable { ... }` with:

```swift
                let isMe = KnownSpeaker.preservedIsMe(
                    forName: newName, in: settings.speakerLibrary.all())
                try? settings.speakerLibrary.learn(
                    name: newName, embedding: embedding,
                    seconds: map.duration(forLabel: newName)
                        ?? KnownSpeaker.legacySampleSeconds,
                    isMe: isMe)
```

(Note: by this point `map.relabel` has already renamed the label to `newName`, so the duration lookup uses `newName`.)

- [ ] **Step 3: Build and full test run** — `swift build && swift test` → PASS (258 + new).

- [ ] **Step 4: Commit** — `feat: wire self-improving voiceprints into processing and rename`

---

### Task 7: REQUIREMENTS.md — add R9c, note sample model in R9/R10

**Files:**
- Modify: `REQUIREMENTS.md` (R9/R10 block, lines ~111-124)

- [ ] **Step 1: Edit** — append after the R9 bullet (keeping the exception clause added by the hardening fix):

```markdown
- **R9c — Self-improving voiceprints.** A known speaker's print is a small set of
  voice samples (bounded; distinct voice modes like headset vs meeting room are
  preserved by merging the closest pair at the cap). Every confidently-attributed
  cluster — an automatic match or an explicit rename that clears the trust gates —
  enriches that speaker's print, so recognition improves with exposure and no
  single meeting can dominate or corrupt a print.
```

And in R10, change "assigned only when (a) it clearly beats the next-nearest different speaker" sentence lead-in to note matching is nearest-sample:

```markdown
  ... A known name is assigned by the nearest of the speaker's stored voice
  samples, and only when (a) it clearly beats the next-nearest different
  speaker (a margin), ...
```

- [ ] **Step 2: Run full tests once more** — `swift test` → PASS.

- [ ] **Step 3: Commit** — `docs: R9c self-improving voiceprints`

---

## Self-review notes

- Spec coverage: data model + migration (T1), min-distance matching (T2/T3), additive learning + reset semantics (T4), auto-refinement (T5/T6), rename feed (T6), requirements (T7). ✔
- Type consistency: `VoiceSample(embedding:seconds:addedAt:)`, `VoicePrint.distance(_:to:)`, `VoicePrint.adding(_:to:cap:)`, `SpeakerLibrary.learn(name:embedding:seconds:isMe:)`, `LibraryRefinement.Update` used identically across tasks. ✔
- The Task 1 bridge in `bestMatch` is deliberately replaced in Task 3 — noted in both. ✔
