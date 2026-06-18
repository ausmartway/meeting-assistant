# Search History (R23) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user filter the saved-meetings list by typing — matching title, date, and transcript text — via a native search field.

**Architecture:** A pure `MeetingSearch` (MeetingKit) filters recordings against a prebuilt per-meeting "haystack" string. `AppState` maintains a `searchIndex` ([id: haystack]) rebuilt whenever the recordings list changes — title+date immediately, transcript text folded in off the main thread. `MainWindowView` adds a `.searchable` field and filters the list through `MeetingSearch`.

**Tech Stack:** Swift, SwiftUI (`.searchable`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-06-19-search-history-design.md`

---

## File structure

- **Create** `Sources/MeetingKit/MeetingSearch.swift` — pure `filter` + `baseHaystack`.
- **Modify** `Sources/MeetingAssistant/AppState.swift` — `searchIndex` + `rebuildSearchIndex()`.
- **Modify** `Sources/MeetingAssistant/MainWindowView.swift` — `.searchable` + filtered list + empty state.
- **Create** `Tests/MeetingKitTests/MeetingSearchTests.swift`.
- **Modify** `REQUIREMENTS.md` — mark R23 implemented.

Reminder for all tasks: this repo uses **4-space indentation** (pinned by `.swift-format`). Stage only the files you change by explicit path; never `git add -A` or stage anything under `.claude/`. No AI/Claude mentions or Co-Authored-By trailers in commit messages. Ignore SourceKit "cannot find type" diagnostics — only trust `swift build`/`swift test`.

---

## Task 1: Pure `MeetingSearch`

**Files:**
- Create: `Sources/MeetingKit/MeetingSearch.swift`
- Test: `Tests/MeetingKitTests/MeetingSearchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite struct MeetingSearchTests {
    func rec(_ id: String, _ title: String) -> MeetingRecording {
        let m = Meeting(
            id: id, title: title,
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 0),
            provider: nil, joinURL: nil)
        return MeetingRecording(
            meeting: m, recordedAt: Date(timeIntervalSince1970: 0),
            micAudioFile: "mic.wav", systemAudioFile: "system.wav",
            timeline: SpeakerTimeline(samples: []))
    }

    let a = "a", b = "b", c = "c"
    var recs: [MeetingRecording] { [rec("a", "Standup"), rec("b", "Weekly Sync"), rec("c", "1:1")] }
    var index: [String: String] {
        ["a": "standup mon jun 18 2026 quarterly numbers",
         "b": "weekly sync jun 18 2026 roadmap planning",
         "c": "1:1 jun 19 2026 career growth"]
    }

    @Test func emptyQueryReturnsAllInOrder() {
        let out = MeetingSearch.filter(recs, query: "", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["a", "b", "c"])
    }

    @Test func whitespaceQueryReturnsAll() {
        #expect(MeetingSearch.filter(recs, query: "   ", haystackByID: index).count == 3)
    }

    @Test func titleSubstringMatch() {
        let out = MeetingSearch.filter(recs, query: "weekly", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["b"])
    }

    @Test func caseInsensitive() {
        let out = MeetingSearch.filter(recs, query: "STANDUP", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["a"])
    }

    @Test func trimmedQuery() {
        let out = MeetingSearch.filter(recs, query: "  roadmap  ", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["b"])
    }

    @Test func dateMatch() {
        let out = MeetingSearch.filter(recs, query: "jun 19", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["c"])
    }

    @Test func transcriptTextMatch() {
        let out = MeetingSearch.filter(recs, query: "career", haystackByID: index)
        #expect(out.map(\.meeting.id) == ["c"])
    }

    @Test func noMatchIsEmpty() {
        #expect(MeetingSearch.filter(recs, query: "zzz", haystackByID: index).isEmpty)
    }

    @Test func recordingAbsentFromIndexIsExcluded() {
        // "b" has no index entry → cannot match a non-empty query.
        let partial = ["a": "standup", "c": "1:1"]
        let out = MeetingSearch.filter(recs, query: "weekly", haystackByID: partial)
        #expect(out.isEmpty)
    }

    @Test func baseHaystackLowercasesAndIncludesTitle() {
        let h = MeetingSearch.baseHaystack(for: rec("x", "Weekly Sync"))
        #expect(h.contains("weekly sync"))
        #expect(h == h.lowercased())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingSearchTests`
Expected: FAIL — `cannot find 'MeetingSearch' in scope`.

- [ ] **Step 3: Implement `Sources/MeetingKit/MeetingSearch.swift`**

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingSearchTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/MeetingSearch.swift Tests/MeetingKitTests/MeetingSearchTests.swift
git commit -m "feat: add pure MeetingSearch filter for meeting history"
```

---

## Task 2: Search index in AppState

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift`

No unit test (`@MainActor` coordinator; verified by build + running). The pure matcher
is covered in Task 1.

- [ ] **Step 1: Add the published index + rebuild task property**

Find the recordings property:

```swift
    @Published private(set) var recordings: [MeetingRecording] = []
```

Replace it with a version that rebuilds the index whenever recordings change:

```swift
    @Published private(set) var recordings: [MeetingRecording] = [] {
        didSet { rebuildSearchIndex() }
    }

    /// Per-meeting lowercased search haystack (title + date + transcript), used by the
    /// sidebar search field. Rebuilt whenever `recordings` changes; transcript text is
    /// folded in off the main thread.
    @Published private(set) var searchIndex: [String: String] = [:]

    /// In-flight transcript-indexing task, cancelled when a newer rebuild starts.
    private var searchIndexTask: Task<Void, Never>?
```

- [ ] **Step 2: Add `rebuildSearchIndex()`**

Add this method to `AppState`:

```swift
    /// Rebuild the search index for the current recordings. The cheap title+date pass
    /// publishes immediately so search works at once; transcript text is read off the
    /// main thread and folded in when ready. A newer rebuild cancels an older one.
    private func rebuildSearchIndex() {
        searchIndexTask?.cancel()
        let recs = recordings
        var base: [String: String] = [:]
        var urls: [(id: String, url: URL)] = []
        for rec in recs {
            base[rec.meeting.id] = MeetingSearch.baseHaystack(for: rec)
            urls.append((rec.meeting.id, store.transcriptURL(for: rec.meeting.id)))
        }
        searchIndex = base
        searchIndexTask = Task.detached { [weak self, base, urls] in
            var full = base
            for (id, url) in urls {
                if Task.isCancelled { return }
                if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                    full[id, default: ""] += " " + text.lowercased()
                }
            }
            if Task.isCancelled { return }
            await MainActor.run { self?.searchIndex = full }
        }
    }
```

- [ ] **Step 3: Build the index once at launch**

The `didSet` does **not** fire for the `self.recordings = store.allRecordings()`
assignment inside `init` (Swift skips property observers during initialization). Add an
explicit call at the END of `init()` (after the existing setup, e.g. right after the
`runRetentionSweep()` line added by the storage feature):

```swift
        rebuildSearchIndex()
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: maintain a searchable index of recordings in AppState"
```

---

## Task 3: Search field + filtered list in the sidebar

**Files:**
- Modify: `Sources/MeetingAssistant/MainWindowView.swift`

No unit test (SwiftUI view; verified by running).

- [ ] **Step 1: Add the search-text state**

In `MainWindowView`, near the other `@State` properties (e.g. after
`@State private var selection: String?`), add:

```swift
    @State private var searchText = ""
```

- [ ] **Step 2: Filter the list and add the empty state**

Replace the existing `sidebarList` body:

```swift
    private var sidebarList: some View {
        List(selection: $selection) {
            // The in-progress recording appears instantly, before it's saved on
            // stop — so a meeting "exists" the moment Record is pressed.
            if let live = state.recording {
                liveRow(live).tag(live.id)
            }
            Section {
                ForEach(state.recordings, id: \.meeting.id) { rec in
                    meetingRow(rec)
                        .tag(rec.meeting.id)
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) { pendingDelete = rec }
                        }
                }
            } header: {
                if !state.recordings.isEmpty { Text("Recent") }
            }
        }
    }
```

with a version that filters through `MeetingSearch` and shows a no-results row:

```swift
    private var sidebarList: some View {
        let results = MeetingSearch.filter(
            state.recordings, query: searchText, haystackByID: state.searchIndex)
        return List(selection: $selection) {
            // The in-progress recording appears instantly, before it's saved on
            // stop — so a meeting "exists" the moment Record is pressed.
            if let live = state.recording {
                liveRow(live).tag(live.id)
            }
            Section {
                if results.isEmpty && !searchText.isEmpty {
                    Text("No meetings match “\(searchText)”")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(results, id: \.meeting.id) { rec in
                    meetingRow(rec)
                        .tag(rec.meeting.id)
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) { pendingDelete = rec }
                        }
                }
            } header: {
                if !state.recordings.isEmpty {
                    Text(searchText.isEmpty ? "Recent" : "Results")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search meetings")
    }
```

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 4: Run to verify behavior**

Run: `./Scripts/build-app.sh --run`. With several saved meetings: a search field appears
on the sidebar; typing part of a meeting **title** filters live; typing a **date**
fragment (e.g. "jun" or the year) filters by date; typing a word that appears only
**inside a transcript** surfaces that meeting (after a moment, once the index finishes);
the header reads "Results" while searching; a non-matching query shows the
"No meetings match …" row; clearing the field restores the full "Recent" list; the live
in-progress row (if recording) stays pinned at top regardless of the query.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingAssistant/MainWindowView.swift
git commit -m "feat: add a search field to filter meeting history (R23)"
```

---

## Task 4: Full verification + requirement status

**Files:**
- Modify: `REQUIREMENTS.md`

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: all suites pass, including `MeetingSearchTests`.

- [ ] **Step 2: Mark R23 implemented**

In `REQUIREMENTS.md`, the **R23** entry currently reads:

```
- **R23 — Search history *(planned)*.** The user can find past meetings by searching
  name/date. *(Not yet implemented.)*
```

Replace it with:

```
- **R23 — Search history.** A search field on the sidebar filters past meetings as the
  user types — matching the meeting name, its date, and the transcript text. Matching
  runs against an in-memory index (rebuilt as recordings change; transcript text folded
  in off the main thread), the in-progress recording stays pinned, and a clear
  "no matches" state shows when nothing matches.
```

- [ ] **Step 3: Commit**

```bash
git add REQUIREMENTS.md
git commit -m "docs: mark R23 (search history) as implemented"
```

---

## Self-review notes

- **Spec coverage:** pure `MeetingSearch.filter` + `baseHaystack` with empty→all,
  case-insensitive, trimmed, title/date/transcript matching, absent-id exclusion
  (Task 1) ✓; AppState `searchIndex` rebuilt via `recordings.didSet` + init call, with
  off-main transcript reads and newer-cancels-older (Task 2) ✓; `.searchable` +
  filtered list + "Recent"/"Results" header + empty-state row + pinned live row
  (Task 3) ✓; REQUIREMENTS update (Task 4) ✓.
- **Placeholder scan:** none — every step shows concrete code.
- **Type consistency:** `MeetingSearch.filter(_:query:haystackByID:)` and
  `baseHaystack(for:)`; `AppState.searchIndex: [String: String]`, `searchIndexTask`,
  `rebuildSearchIndex()`; `store.transcriptURL(for:)` (existing) returns `URL`; the view
  uses `state.searchIndex` and `searchText` consistently.
- **Out of scope (per spec):** fuzzy/ranked relevance, regex, match highlighting,
  on-disk index persistence.
