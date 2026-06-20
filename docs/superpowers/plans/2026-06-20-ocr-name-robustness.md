# OCR speaker-name robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make on-screen speaker-name OCR (R10b) more accurate via name normalization/dedup, multi-frame voting, and Vision confidence thresholding.

**Architecture:** Two new pure MeetingKit modules — `SpeakerNameNormalizer` (clean + canonical-key a name) and `SpeakerTimelineConsolidator` (vote across frames) — are unit-tested with swift-testing. The consolidator runs in `MeetingProcessor` post-processing, just before `SpeakerFuser.fuse`. `SpeakerSampler` gets two integration-layer changes: filter Vision candidates by `.confidence`, and pass the OCR result through `SpeakerNameNormalizer.displayName`. The live-capture structure is unchanged.

**Tech Stack:** Swift, SwiftPM, swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`), Vision (`VNRecognizeTextRequest`).

---

## File Structure

- **Create** `Sources/MeetingKit/SpeakerNameNormalizer.swift` — pure name cleaning + canonical-key folding.
- **Create** `Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift` — its suite.
- **Create** `Sources/MeetingKit/SpeakerTimelineConsolidator.swift` — pure multi-frame voting over a `SpeakerTimeline`.
- **Create** `Tests/MeetingKitTests/SpeakerTimelineConsolidatorTests.swift` — its suite.
- **Modify** `Sources/MeetingKit/MeetingProcessor.swift:94-105` — consolidate the timeline before fusing.
- **Modify** `Sources/MeetingKit/SpeakerSampler.swift:138-160` — confidence filter + `displayName` pass.

---

## Task 1: SpeakerNameNormalizer — displayName

**Files:**
- Create: `Sources/MeetingKit/SpeakerNameNormalizer.swift`
- Test: `Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift`:

```swift
import Testing
@testable import MeetingKit

@Suite("SpeakerNameNormalizer.displayName")
struct SpeakerNameNormalizerDisplayNameTests {

    @Test("trims and collapses internal whitespace")
    func collapsesWhitespace() {
        #expect(SpeakerNameNormalizer.displayName("  John   Smith ") == "John Smith")
    }

    @Test("strips trailing English role markers, case-insensitively")
    func stripsEnglishRoles() {
        #expect(SpeakerNameNormalizer.displayName("John Smith (Host)") == "John Smith")
        #expect(SpeakerNameNormalizer.displayName("Jane Doe (You)") == "Jane Doe")
        #expect(SpeakerNameNormalizer.displayName("Sam (co-host)") == "Sam")
        #expect(SpeakerNameNormalizer.displayName("Pat (Guest)") == "Pat")
    }

    @Test("strips trailing Chinese role markers")
    func stripsChineseRoles() {
        #expect(SpeakerNameNormalizer.displayName("王伟（主持人）") == "王伟")
    }

    @Test("returns nil for empty or too-short results")
    func nilForEmpty() {
        #expect(SpeakerNameNormalizer.displayName("") == nil)
        #expect(SpeakerNameNormalizer.displayName("   ") == nil)
        #expect(SpeakerNameNormalizer.displayName("(Host)") == nil)
        #expect(SpeakerNameNormalizer.displayName("A") == nil)
    }

    @Test("leaves a clean name untouched")
    func leavesCleanName() {
        #expect(SpeakerNameNormalizer.displayName("Mei Chen") == "Mei Chen")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerNameNormalizer`
Expected: FAIL — `cannot find 'SpeakerNameNormalizer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MeetingKit/SpeakerNameNormalizer.swift`:

```swift
import Foundation

/// Pure cleaning + grouping helpers for OCR'd participant names.
///
/// `displayName` produces the label we show; `canonicalKey` produces a folded key
/// used only to group trivial variants (whitespace/case/diacritics) of the same
/// name during multi-frame voting. Both are deterministic and unit-tested.
public enum SpeakerNameNormalizer {

    /// Trailing role/parenthetical markers meeting apps append to a name.
    /// Matched case-insensitively, with either ASCII `()` or fullwidth `（）`.
    private static let roleMarkers: Set<String> = [
        "host", "co-host", "cohost", "you", "me", "guest", "organizer", "organiser",
        "主持人", "你", "我", "联席主持人", "聯席主持人", "访客", "訪客",
    ]

    /// A cleaned display name, or nil if nothing name-like remains.
    public static func displayName(_ raw: String) -> String? {
        // Strip a single trailing "(...)" / "（...）" group if its content is a role marker.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = strippingTrailingRole(s) { s = stripped }
        // Collapse internal whitespace runs to single spaces.
        let collapsed = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject empties and single characters (not a usable name).
        guard collapsed.count >= 2 else { return nil }
        return collapsed
    }

    /// Folded key for grouping variants: lowercased, diacritics-removed, whitespace removed.
    public static func canonicalKey(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.filter { !$0.isWhitespace }
    }

    /// If `s` ends in a "(role)" / "（role）" group, return `s` without it; else nil.
    private static func strippingTrailingRole(_ s: String) -> String? {
        let pairs: [(Character, Character)] = [("(", ")"), ("（", "）")]
        for (open, close) in pairs where s.hasSuffix(String(close)) {
            guard let openIdx = s.lastIndex(of: open) else { continue }
            let inside = s[s.index(after: openIdx)..<s.index(before: s.endIndex)]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if roleMarkers.contains(inside) {
                return String(s[..<openIdx]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerNameNormalizer`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerNameNormalizer.swift Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift
git commit -m "feat: add SpeakerNameNormalizer for OCR name cleaning + dedup keys"
```

---

## Task 2: SpeakerNameNormalizer — canonicalKey

**Files:**
- Test: `Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift` (add a suite)

- [ ] **Step 1: Write the failing test**

Append to `Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift`:

```swift
@Suite("SpeakerNameNormalizer.canonicalKey")
struct SpeakerNameNormalizerCanonicalKeyTests {

    @Test("folds case and whitespace to one key")
    func foldsCaseAndWhitespace() {
        #expect(
            SpeakerNameNormalizer.canonicalKey("John Smith")
            == SpeakerNameNormalizer.canonicalKey("john  smith")
        )
    }

    @Test("folds diacritics")
    func foldsDiacritics() {
        #expect(
            SpeakerNameNormalizer.canonicalKey("José")
            == SpeakerNameNormalizer.canonicalKey("Jose")
        )
    }

    @Test("different names get different keys")
    func differentNames() {
        #expect(
            SpeakerNameNormalizer.canonicalKey("John Smith")
            != SpeakerNameNormalizer.canonicalKey("Jane Smith")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

The implementation from Task 1 already provides `canonicalKey`.
Run: `swift test --filter SpeakerNameNormalizer`
Expected: PASS (all 8 tests now). If any fail, fix `canonicalKey` in `SpeakerNameNormalizer.swift`.

- [ ] **Step 3: Commit**

```bash
git add Tests/MeetingKitTests/SpeakerNameNormalizerTests.swift
git commit -m "test: cover SpeakerNameNormalizer.canonicalKey folding"
```

---

## Task 3: SpeakerTimelineConsolidator — variant snapping (Step A)

**Files:**
- Create: `Sources/MeetingKit/SpeakerTimelineConsolidator.swift`
- Test: `Tests/MeetingKitTests/SpeakerTimelineConsolidatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/SpeakerTimelineConsolidatorTests.swift`:

```swift
import Testing
@testable import MeetingKit

@Suite("SpeakerTimelineConsolidator")
struct SpeakerTimelineConsolidatorTests {

    /// Build a timeline from (timestamp, name?) pairs.
    private func timeline(_ pairs: [(TimeInterval, String?)]) -> SpeakerTimeline {
        SpeakerTimeline(samples: pairs.map { SpeakerSample(timestamp: $0.0, speakerName: $0.1) })
    }

    private func names(_ t: SpeakerTimeline) -> [String?] {
        t.samples.map(\.speakerName)
    }

    @Test("empty timeline passes through")
    func empty() {
        let out = SpeakerTimelineConsolidator.consolidate(timeline([]))
        #expect(out.samples.isEmpty)
    }

    @Test("variant snapping rewrites all members to the most-frequent display")
    func variantSnapping() {
        // The John cluster: "John Smith" twice + one whitespace/case variant.
        // Jane is kept in two adjacent samples so Step B (Task 4) won't later
        // treat her as an isolated outlier — this test isolates Step A's behavior.
        let input = timeline([
            (0, "John Smith"), (1, "John Smith"), (2, "john  smith"),
            (3, "Jane Doe"), (4, "Jane Doe"),
        ])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        // The whitespace/case variant at index 2 snaps to the winning "John Smith".
        #expect(names(out) == ["John Smith", "John Smith", "John Smith", "Jane Doe", "Jane Doe"])
    }

    @Test("timestamps are preserved")
    func timestampsPreserved() {
        let input = timeline([(0, "A B"), (5, "a  b")])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(out.samples.map(\.timestamp) == [0, 5])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerTimelineConsolidator`
Expected: FAIL — `cannot find 'SpeakerTimelineConsolidator' in scope`.

- [ ] **Step 3: Write minimal implementation (Step A only)**

Create `Sources/MeetingKit/SpeakerTimelineConsolidator.swift`:

```swift
import Foundation

/// Multi-frame voting over an OCR active-speaker timeline.
///
/// OCR is the fragile signal (see `SpeakerSampler`), so a per-frame name can be a
/// misread that then "holds" until the next sample in `SpeakerFuser`. This pure,
/// deterministic pass cleans the timeline before fusion in two steps:
///
///  - **A. Variant snapping** — trivial variants of one name (whitespace/case/
///    role-suffix) are grouped by `SpeakerNameNormalizer.canonicalKey` and the
///    most-frequent display variant in each group wins.
///  - **B. Isolated-outlier suppression** — a lone differing read between two
///    samples of the same other name is treated as noise (added in Task 4).
///
/// Runs in `MeetingProcessor` post-processing, never in the live capture path.
public enum SpeakerTimelineConsolidator {

    public static func consolidate(_ timeline: SpeakerTimeline) -> SpeakerTimeline {
        let snapped = snapVariants(timeline.samples)
        return SpeakerTimeline(samples: snapped)
    }

    /// Step A: rewrite every named sample to the most-frequent display in its
    /// canonical-key cluster. Ties broken by first appearance for determinism.
    private static func snapVariants(_ samples: [SpeakerSample]) -> [SpeakerSample] {
        // For each canonical key: counts per display, and first-seen order.
        var counts: [String: [String: Int]] = [:]
        var firstSeen: [String: Int] = [:]
        for (i, s) in samples.enumerated() {
            guard let name = s.speakerName else { continue }
            let key = SpeakerNameNormalizer.canonicalKey(name)
            counts[key, default: [:]][name, default: 0] += 1
            if firstSeen[name] == nil { firstSeen[name] = i }
        }
        // Winning display per key: highest count; ties broken by earliest first-seen.
        var winner: [String: String] = [:]
        for (key, byDisplay) in counts {
            winner[key] = byDisplay.max { a, b in
                if a.value != b.value { return a.value < b.value }
                return (firstSeen[a.key] ?? 0) > (firstSeen[b.key] ?? 0)
            }?.key
        }
        return samples.map { s in
            guard let name = s.speakerName else { return s }
            let key = SpeakerNameNormalizer.canonicalKey(name)
            return SpeakerSample(timestamp: s.timestamp, speakerName: winner[key] ?? name)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerTimelineConsolidator`
Expected: PASS (all 3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerTimelineConsolidator.swift Tests/MeetingKitTests/SpeakerTimelineConsolidatorTests.swift
git commit -m "feat: add SpeakerTimelineConsolidator variant snapping (vote step A)"
```

---

## Task 4: SpeakerTimelineConsolidator — isolated-outlier suppression (Step B)

**Files:**
- Modify: `Sources/MeetingKit/SpeakerTimelineConsolidator.swift`
- Test: `Tests/MeetingKitTests/SpeakerTimelineConsolidatorTests.swift` (add tests)

- [ ] **Step 1: Write the failing test**

Append inside `struct SpeakerTimelineConsolidatorTests`:

```swift
    @Test("lone differing read between two same neighbors is replaced by the neighbor")
    func isolatedOutlierReplacedByAgreeingNeighbors() {
        let input = timeline([(0, "Alice"), (1, "Bob"), (2, "Alice")])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(names(out) == ["Alice", "Alice", "Alice"])
    }

    @Test("lone read between two disagreeing neighbors is nilled")
    func isolatedOutlierNilledWhenNeighborsDisagree() {
        let input = timeline([(0, "Alice"), (1, "Bob"), (2, "Carol")])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(names(out) == ["Alice", nil, "Carol"])
    }

    @Test("a name held across multiple samples is not suppressed")
    func stableNameKept() {
        let input = timeline([(0, "Alice"), (1, "Bob"), (2, "Bob"), (3, "Alice")])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(names(out) == ["Alice", "Bob", "Bob", "Alice"])
    }

    @Test("single-sample timeline passes through")
    func singleSample() {
        let input = timeline([(0, "Alice")])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(names(out) == ["Alice"])
    }

    @Test("all-nil timeline passes through")
    func allNil() {
        let input = timeline([(0, nil), (1, nil)])
        let out = SpeakerTimelineConsolidator.consolidate(input)
        #expect(names(out) == [nil, nil])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerTimelineConsolidator`
Expected: FAIL — `isolatedOutlierReplacedByAgreeingNeighbors` and `isolatedOutlierNilledWhenNeighborsDisagree` fail (suppression not implemented). The other three pass.

- [ ] **Step 3: Implement Step B**

In `Sources/MeetingKit/SpeakerTimelineConsolidator.swift`, change `consolidate` to chain the second pass:

```swift
    public static func consolidate(_ timeline: SpeakerTimeline) -> SpeakerTimeline {
        let snapped = snapVariants(timeline.samples)
        let cleaned = suppressIsolatedOutliers(snapped)
        return SpeakerTimeline(samples: cleaned)
    }
```

Then add this method below `snapVariants`:

```swift
    /// Step B: a single sample whose name differs from BOTH its immediate
    /// neighbors is a likely misread. If the two neighbors agree, adopt their
    /// name; if they disagree (or a neighbor is missing), drop to nil. A name that
    /// persists across two or more adjacent samples is never suppressed.
    private static func suppressIsolatedOutliers(_ samples: [SpeakerSample]) -> [SpeakerSample] {
        guard samples.count >= 3 else { return samples }
        var result = samples
        for i in 1..<(samples.count - 1) {
            let prev = samples[i - 1].speakerName
            let curr = samples[i].speakerName
            let next = samples[i + 1].speakerName
            guard let curr, curr != prev, curr != next else { continue }
            // curr is isolated (differs from both neighbors).
            let replacement = (prev != nil && prev == next) ? prev : nil
            result[i] = SpeakerSample(timestamp: samples[i].timestamp, speakerName: replacement)
        }
        return result
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerTimelineConsolidator`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/SpeakerTimelineConsolidator.swift Tests/MeetingKitTests/SpeakerTimelineConsolidatorTests.swift
git commit -m "feat: suppress isolated OCR outliers in timeline (vote step B)"
```

---

## Task 5: Wire consolidation into MeetingProcessor

**Files:**
- Modify: `Sources/MeetingKit/MeetingProcessor.swift:94-105`

- [ ] **Step 1: Make the change**

In `Sources/MeetingKit/MeetingProcessor.swift`, locate the fusion block (around line 99) that reads:

```swift
        let micLabels = SpeakerRecognizer.resolve(outcome: outcome, knownSpeakers: knownSpeakers)
        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: recording.timeline,
            micDiarization: outcome.spans,
            micLabels: micLabels,
            micLabel: localUserName
        )
```

Replace it with:

```swift
        let micLabels = SpeakerRecognizer.resolve(outcome: outcome, knownSpeakers: knownSpeakers)
        // Multi-frame voting cleans OCR misreads/variants before fusion (post-processing).
        let consolidatedTimeline = SpeakerTimelineConsolidator.consolidate(recording.timeline)
        let labeled = SpeakerFuser.fuse(
            segments: cleaned,
            timeline: consolidatedTimeline,
            micDiarization: outcome.spans,
            micLabels: micLabels,
            micLabel: localUserName
        )
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --target MeetingKit`
Expected: Build succeeds.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS (no regressions; existing `SpeakerFuser`/`MeetingProcessor` suites still green).

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingKit/MeetingProcessor.swift
git commit -m "feat: consolidate OCR timeline before speaker fusion"
```

---

## Task 6: Confidence threshold + normalization in SpeakerSampler

**Files:**
- Modify: `Sources/MeetingKit/SpeakerSampler.swift:138-160`

> No unit test — `recognizeName` needs Vision (real system access), which the
> project does not unit-test. Verified by building and by running the app.

- [ ] **Step 1: Make the change**

In `Sources/MeetingKit/SpeakerSampler.swift`, add a threshold constant just above the `// MARK: - OCR` section's `recognizeName`:

```swift
    /// Reject OCR candidates below this Vision confidence (0–1). Low-confidence
    /// reads return nil → SpeakerFuser degrades to "Speaker" rather than asserting
    /// a confident-wrong name.
    private let nameConfidenceThreshold: Float = 0.4
```

Then replace the body of `recognizeName` (the `withCheckedContinuation` closure) so it filters by confidence and normalizes the result. The full method becomes:

```swift
    private func recognizeName(in pixelBuffer: CVPixelBuffer, regionOfInterest: CGRect) async -> String? {
        // Name labels typically occupy the bottom ~20% of a tile.
        let nameStrip = CGRect(
            x: regionOfInterest.minX,
            y: regionOfInterest.minY,
            width: regionOfInterest.width,
            height: max(0.05, regionOfInterest.height * 0.2)
        )
        let threshold = nameConfidenceThreshold
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                // Keep only candidates Vision is reasonably confident about.
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first }
                    .filter { $0.confidence >= threshold }
                    .map(\.string) ?? []
                // Normalize the chosen name (strip roles, collapse whitespace).
                let best = Self.bestName(from: lines).flatMap(SpeakerNameNormalizer.displayName)
                continuation.resume(returning: best)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Recognize both Chinese (simplified + traditional) and English names.
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.regionOfInterest = nameStrip
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --target MeetingKit`
Expected: Build succeeds.

- [ ] **Step 3: Run the full suite (no regressions)**

Run: `swift test`
Expected: PASS. The existing `SpeakerSampler.bestName` tests still pass (its signature is unchanged).

- [ ] **Step 4: Commit**

```bash
git add Sources/MeetingKit/SpeakerSampler.swift
git commit -m "feat: filter OCR names by Vision confidence + normalize display"
```

---

## Task 7: Update REQUIREMENTS.md note for R10b

**Files:**
- Modify: `REQUIREMENTS.md:121-126` (R10b)

- [ ] **Step 1: Make the change**

In `REQUIREMENTS.md`, at the end of the R10b paragraph (after "…doesn't read as a failure."), append one sentence documenting the robustness pass:

```markdown
  On-screen reads are made more reliable by post-processing: low-confidence OCR is
  rejected, trivial name variants (whitespace, "(Host)"/"(You)", case) are merged,
  and isolated single-frame misreads are voted out across samples
  (`SpeakerTimelineConsolidator`, `SpeakerNameNormalizer`).
```

- [ ] **Step 2: Verify it reads correctly**

Run: `rg -n -A2 "Best-effort on-screen names" REQUIREMENTS.md`
Expected: shows the R10b paragraph with the new sentence appended.

- [ ] **Step 3: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: note OCR robustness pass in R10b"
```

---

## Verification (after all tasks)

- [ ] `swift test` — all suites green, including the two new ones.
- [ ] `swift build` — full build (library + app) succeeds.
- [ ] Manual (optional, per project policy): run the app on a real meeting and
      confirm remote speakers are named without spurious one-frame name flips.
