# Search history (R23) — design

**Requirement:** R23 (find past meetings by searching name/date — extended to transcript text)
**Date:** 2026-06-19
**Status:** Approved, ready for implementation plan

## Problem

The main window lists saved recordings newest-first but offers no way to find one in a
large history. R23 asks for search by name/date; the owner extended it to also search
**inside transcript text** (find a meeting by what was said).

## Decisions (settled in brainstorming)

- **Match against title + displayed date + transcript text** (case-insensitive
  substring). Date is the same formatted string shown in the row, so typing "jun",
  "18", or "2026" works.
- **In-memory index** so per-keystroke filtering does no file I/O.
- **Native `.searchable`** field on the sidebar.
- Order stays newest-first; the live in-progress row is never filtered out.

## Architecture

### 1. Pure matcher `MeetingSearch` (MeetingKit, TDD core)

```swift
public enum MeetingSearch {
    /// Filter recordings by a free-text query, preserving input order. An empty or
    /// whitespace-only query returns all recordings. Otherwise keeps those whose
    /// prebuilt haystack (lowercased title + date + transcript) contains the
    /// lowercased, trimmed query. Pure — no file I/O — so it is fully unit-testable.
    public static func filter(
        _ recordings: [MeetingRecording],
        query: String,
        haystackByID: [String: String]
    ) -> [MeetingRecording]
}
```

- Empty/whitespace query → return `recordings` unchanged.
- Else `let q = query.lowercased().trimmed`; keep `rec` where
  `haystackByID[rec.meeting.id]?.contains(q) == true`.
- The matcher stays dead simple: it only consults `haystackByID`. A recording with no
  entry is non-matching for a non-empty query. In practice this is a non-issue because
  the index publishes every recording's title+date haystack almost immediately (see
  §2), so the only thing that lags is transcript-text matches.

### 2. Search index (AppState)

- `@Published private(set) var searchIndex: [String: String] = [:]` — meetingID → a
  single **lowercased** haystack string: `title + " " + formattedDate + " " + transcript`.
- **Built asynchronously** in a background `Task` whenever the recordings list changes
  (load, finish, rename, delete). Reading each recording's transcript (via the store)
  happens only here, off the keystroke path.
- The build first composes title + date for every recording (cheap) and publishes,
  then folds in transcript text as each file is read — so title/date search works
  immediately and transcript matches appear once the build completes.
- `formattedDate` uses the same format the row shows
  (`.formatted(date: .abbreviated, time: .shortened)`), lowercased, so the displayed
  date is searchable.

### 3. UI (`MainWindowView`)

- `@State private var searchText = ""`.
- `.searchable(text: $searchText, placement: .sidebar)` (or the platform default) on
  the sidebar `List`.
- The `ForEach` iterates
  `MeetingSearch.filter(state.recordings, query: searchText, haystackByID: state.searchIndex)`
  instead of `state.recordings`.
- The live in-progress row (`state.recording`) stays pinned at top regardless of the
  query.
- Section header reads **"Recent"** with no query and **"Results"** with a query.
- **Empty-results state:** when a non-empty query matches nothing, show a quiet
  "No meetings match \"<query>\"" row rather than an empty list.

## Error handling / edge cases

- **Empty query:** full list, unchanged order (no filtering work).
- **Transcript not yet generated (in-progress/failed):** haystack is title + date only;
  the recording is still findable by name/date.
- **Index not built yet at first launch:** the title+date pass publishes quickly;
  transcript matches become available a moment later. No blocking, no spinner needed.
- **Rename / delete / re-transcribe:** the recordings-changed hook rebuilds the index
  so stale entries don't linger.
- **No matches:** explicit empty-state row, never a silent blank list.

## Testing

- `MeetingSearch.filter` unit-tested (swift-testing), pure:
  - empty / whitespace query → all recordings, order preserved;
  - title substring match (case-insensitive);
  - date substring match (e.g. "2026");
  - transcript-text match;
  - trimmed query;
  - no match → empty;
  - a recording id absent from `haystackByID` is excluded for a non-empty query.
- The async index build and `.searchable` UI are verified by running (per N8): typing
  filters the list live, the in-progress row stays, transcript-text hits appear, and
  the empty-state row shows on no match.

## Out of scope (YAGNI)

- Fuzzy/ranked relevance, regex, match highlighting within transcripts.
- Searching speaker names as a distinct field (covered incidentally when the name
  appears in the title or transcript).
- Persisting a search index to disk (rebuilt in memory each launch).
