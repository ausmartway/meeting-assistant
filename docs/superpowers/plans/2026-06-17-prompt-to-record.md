# Prompt-to-record Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace silent auto-start of meeting capture with an actionable "Start recording?" notification whose **Start Recording** button begins capture only on user consent.

**Architecture:** A new pure helper `MeetingNotification` (in MeetingKit) builds and parses the notification's `userInfo` payload and resolves it back to a `Meeting`. A new `@MainActor` `NotificationCoordinator` (in the app target) registers the notification category/action and conforms to `UNUserNotificationCenterDelegate`, calling back into `AppState` when the user taps Start. `AppState.tick()` now prompts instead of auto-starting; the old `notifyAndStart` is removed.

**Tech Stack:** Swift, SwiftUI, UserNotifications (`UNUserNotificationCenter`), swift-testing.

---

## File Structure

- **Create** `Sources/MeetingKit/MeetingNotification.swift` — pure namespace: notification identifiers, `userInfo(for:)` builder, and `resolve(userInfo:upcoming:now:)` parser. Testable without any UI or system frameworks.
- **Create** `Tests/MeetingKitTests/MeetingNotificationTests.swift` — unit tests for the resolver (in-list match, ad-hoc reconstruction, malformed payload).
- **Create** `Sources/MeetingAssistant/NotificationCoordinator.swift` — `@MainActor` `UNUserNotificationCenterDelegate`: category/action registration + action handling, weak ref to `AppState`.
- **Modify** `Sources/MeetingAssistant/AppState.swift` — replace `notifyAndStart` with `promptToRecord`; add `startCaptureFromNotification`; add actionable-notification poster; own + wire the coordinator in `start()`.

`Meeting`/`MeetingProvider` already live in `Sources/MeetingKit/Models.swift`; no changes there.

---

### Task 1: Pure notification payload helper (`MeetingNotification`)

**Files:**
- Create: `Sources/MeetingKit/MeetingNotification.swift`
- Test: `Tests/MeetingKitTests/MeetingNotificationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MeetingKitTests/MeetingNotificationTests.swift`:

```swift
import Testing
import Foundation
@testable import MeetingKit

@Suite("MeetingNotification.resolve")
struct MeetingNotificationTests {

    private func meeting(id: String, title: String = "Standup", provider: MeetingProvider? = .zoom) -> Meeting {
        Meeting(
            id: id,
            title: title,
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 1000 + 1800),
            provider: provider,
            joinURL: nil
        )
    }

    @Test("round-trips userInfo and returns the live meeting when still upcoming")
    func resolvesFromUpcoming() {
        let live = meeting(id: "abc", title: "Standup", provider: .googleMeet)
        let info = MeetingNotification.userInfo(for: live)
        let resolved = MeetingNotification.resolve(
            userInfo: info, upcoming: [live], now: Date(timeIntervalSince1970: 2000)
        )
        #expect(resolved == live)   // exact meeting, with real dates/joinURL preserved
    }

    @Test("reconstructs an ad-hoc meeting from the payload when no longer upcoming")
    func reconstructsWhenGone() {
        let info = MeetingNotification.userInfo(for: meeting(id: "abc", title: "Sync", provider: .microsoftTeams))
        let now = Date(timeIntervalSince1970: 5000)
        let resolved = MeetingNotification.resolve(userInfo: info, upcoming: [], now: now)
        #expect(resolved?.id == "abc")
        #expect(resolved?.title == "Sync")
        #expect(resolved?.provider == .microsoftTeams)
        #expect(resolved?.startDate == now)
        #expect(resolved?.endDate == now.addingTimeInterval(2 * 60 * 60))
        #expect(resolved?.joinURL == nil)
    }

    @Test("preserves a nil provider through reconstruction")
    func reconstructsWithoutProvider() {
        let info = MeetingNotification.userInfo(for: meeting(id: "x", title: "Chat", provider: nil))
        let resolved = MeetingNotification.resolve(userInfo: info, upcoming: [], now: Date(timeIntervalSince1970: 0))
        #expect(resolved?.provider == nil)
        #expect(resolved?.title == "Chat")
    }

    @Test("returns nil for a payload missing the meeting id")
    func nilOnMalformedPayload() {
        let resolved = MeetingNotification.resolve(userInfo: ["unrelated": "value"], upcoming: [], now: Date())
        #expect(resolved == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter MeetingNotification`
Expected: FAIL — `cannot find 'MeetingNotification' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/MeetingKit/MeetingNotification.swift`:

```swift
import Foundation

/// Pure helpers for the "meeting detected" actionable notification: the stable
/// category/action identifiers, building the `userInfo` payload from a `Meeting`,
/// and resolving a payload back into a `Meeting` when the user taps Start.
///
/// Kept free of UserNotifications/UI types so the round-trip and the late-click
/// reconstruction are unit-testable without system access.
public enum MeetingNotification {
    /// Category attached to the prompt so its action button is shown.
    public static let categoryID = "MEETING_DETECTED"
    /// The single "Start Recording" action's identifier.
    public static let startActionID = "START_RECORDING"

    private static let idKey = "meetingID"
    private static let titleKey = "meetingTitle"
    private static let providerKey = "meetingProvider"

    /// Encode the bits we need to resume into a notification payload. Provider is
    /// stored as its raw value (omitted when nil) so a late tap can reconstruct an
    /// ad-hoc meeting if the meeting has left the upcoming list.
    public static func userInfo(for meeting: Meeting) -> [String: String] {
        var info: [String: String] = [
            idKey: meeting.id,
            titleKey: meeting.title,
        ]
        if let provider = meeting.provider {
            info[providerKey] = provider.rawValue
        }
        return info
    }

    /// Resolve a tapped notification's payload to a meeting to record.
    /// - Prefers the live meeting still in `upcoming` (keeps real dates/joinURL).
    /// - Falls back to reconstructing an ad-hoc meeting from the payload (a 2h
    ///   window starting at `now`) so a late tap still records.
    /// - Returns nil when the payload has no meeting id (malformed).
    public static func resolve(
        userInfo: [AnyHashable: Any],
        upcoming: [Meeting],
        now: Date
    ) -> Meeting? {
        guard let id = userInfo[idKey] as? String else { return nil }
        if let live = upcoming.first(where: { $0.id == id }) {
            return live
        }
        let title = (userInfo[titleKey] as? String) ?? "Meeting"
        let provider = (userInfo[providerKey] as? String).flatMap(MeetingProvider.init(rawValue:))
        return Meeting(
            id: id,
            title: title,
            startDate: now,
            endDate: now.addingTimeInterval(2 * 60 * 60),
            provider: provider,
            joinURL: nil
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter MeetingNotification`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetingKit/MeetingNotification.swift Tests/MeetingKitTests/MeetingNotificationTests.swift
git commit -m "feat: add MeetingNotification payload helper for prompt-to-record"
```

---

### Task 2: NotificationCoordinator (category registration + action handling)

**Files:**
- Create: `Sources/MeetingAssistant/NotificationCoordinator.swift`

No unit test: this is a UserNotifications-framework integration (delegate + category registration), verified by running the app per the project's testing policy. Its pure logic already lives in `MeetingNotification` (Task 1).

- [ ] **Step 1: Write the implementation**

Create `Sources/MeetingAssistant/NotificationCoordinator.swift`:

```swift
import Foundation
import UserNotifications
import MeetingKit

/// Owns the "meeting detected" notification category and acts as the system's
/// notification delegate. When the user taps **Start Recording**, it resolves the
/// payload and asks `AppState` to begin capture. Registration and delegate
/// callbacks are the only notification-framework wiring in the app.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    /// Weak so the coordinator never keeps the app coordinator alive.
    weak var appState: AppState?

    /// Become the notification delegate and register the actionable category.
    /// Call once at launch. Safe to call before notification permission is granted
    /// — the category just goes unused until a prompt is posted.
    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(
            identifier: MeetingNotification.startActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: MeetingNotification.categoryID,
            actions: [start],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Show the prompt even when the app is frontmost — otherwise a foreground app
    /// would swallow its own "Start recording?" banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tapping Start Recording lands here. Hop to the main actor, resolve the
    /// payload, and begin capture.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if actionID == MeetingNotification.startActionID {
                appState?.startCaptureFromNotification(userInfo: userInfo)
            }
            completionHandler()
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (an "unused" warning is fine; `startCaptureFromNotification` is added in Task 3 — if the build fails only on that missing method, proceed to Task 3 then rebuild).

- [ ] **Step 3: Commit**

```bash
git add Sources/MeetingAssistant/NotificationCoordinator.swift
git commit -m "feat: add NotificationCoordinator for prompt-to-record action"
```

---

### Task 3: Switch AppState from auto-start to prompt

**Files:**
- Modify: `Sources/MeetingAssistant/AppState.swift`

- [ ] **Step 1: Add the coordinator property**

In `AppState`, next to the other private stored properties (after line 77, `private var notifiedMeetingIDs: Set<String> = []`), add:

```swift
    /// Registers the actionable notification + handles the user tapping "Start
    /// Recording" on a detected meeting.
    private let notificationCoordinator = NotificationCoordinator()
```

- [ ] **Step 2: Wire the coordinator in `start()`**

In `start()` (currently lines 171–178), after `refreshUpcoming()` and before `Task { await prepareModel() }`, add the two wiring lines so the block reads:

```swift
    func start() {
        applyDockIconSetting()
        refreshUpcoming()
        notificationCoordinator.appState = self
        notificationCoordinator.register()
        Task { await prepareModel() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
```

- [ ] **Step 3: Point `tick()` at the prompt**

In `tick()` (lines 217–226), replace the loop body call `notifyAndStart(meeting)` with `promptToRecord(meeting)`:

```swift
    private func tick() {
        refreshUpcoming()
        // We never start recording on our own anymore — detection only prompts.
        // Skip prompting while a capture is already running.
        guard recording == nil else { return }
        for meeting in upcoming where detector.shouldAutoStart(meeting) {
            promptToRecord(meeting)
            break
        }
    }
```

(Leave `MeetingDetector.shouldAutoStart` as-is — it reports "meeting is live and its app is running", which is still exactly the prompt trigger. Renaming it is out of scope.)

- [ ] **Step 4: Replace `notifyAndStart` with `promptToRecord`**

Replace the whole `notifyAndStart` method (lines 255–264) with:

```swift
    /// A meeting was detected as live: prompt the user (once) with an actionable
    /// notification. Capture starts only if they tap "Start Recording" — handled by
    /// `NotificationCoordinator` → `startCaptureFromNotification`.
    private func promptToRecord(_ meeting: Meeting) {
        guard !notifiedMeetingIDs.contains(meeting.id) else { return }
        notifiedMeetingIDs.insert(meeting.id)
        postPromptNotification(
            title: "Start recording?",
            body: "“\(meeting.title)” looks like it has started. Tap Start Recording to capture and transcribe it.",
            meeting: meeting
        )
    }

    /// Called by `NotificationCoordinator` when the user taps "Start Recording".
    /// Resolves the payload (live meeting, or a reconstructed ad-hoc one) and
    /// starts capture. A no-op if resolution fails or a capture is already active
    /// (`startCapture` guards `recording == nil`).
    func startCaptureFromNotification(userInfo: [AnyHashable: Any]) {
        guard let meeting = MeetingNotification.resolve(
            userInfo: userInfo, upcoming: upcoming, now: Date()
        ) else { return }
        Task { await startCapture(for: meeting) }
    }
```

- [ ] **Step 5: Add the actionable-notification poster**

In the `// MARK: - Notifications` section, alongside `postNotification` (lines 472–479), add a sibling that attaches the category + payload:

```swift
    /// Post the actionable "Start recording?" prompt: same as `postNotification`
    /// but carries the category (so the Start button shows) and the meeting payload
    /// the action handler resolves.
    private func postPromptNotification(title: String, body: String, meeting: Meeting) {
        guard permissions.notifications == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = MeetingNotification.categoryID
        content.userInfo = MeetingNotification.userInfo(for: meeting)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds cleanly. If the compiler reports `notifyAndStart` is still referenced, search and confirm it was the only call site (it was `tick()`): `rg -n "notifyAndStart" Sources/` should return nothing.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: PASS, including the Task 1 `MeetingNotification` suite. (No existing test referenced `notifyAndStart`, so nothing else should break.)

- [ ] **Step 8: Commit**

```bash
git add Sources/MeetingAssistant/AppState.swift
git commit -m "feat: prompt to record instead of auto-starting capture"
```

---

### Task 4: Manual verification (run the app)

**Files:** none — behavioral verification per the project's "integrations verified by running the app" policy.

- [ ] **Step 1: Build and launch the signed app**

Run: `./Scripts/build-app.sh --run`
Expected: app launches; menu-bar icon appears.

- [ ] **Step 2: Trigger detection**

Start (or join) a Zoom/Meet/Teams meeting that matches an upcoming calendar event, or one whose client app is running, so `MeetingDetector.shouldAutoStart` fires within the 30s poll.
Expected: a **"Start recording?"** notification appears with a **Start Recording** button. **No recording starts on its own** (menu bar still shows "Watching for meetings"; icon is not the record dot).

- [ ] **Step 3: Accept the prompt**

Click **Start Recording** on the notification.
Expected: capture begins — the menu bar shows "Recording: …" and the icon becomes the filled record dot. The follow-up "Recording started" notification appears.

- [ ] **Step 4: Confirm once-per-meeting + ignore path**

Dismiss the prompt without clicking (in a separate detected meeting) and wait through another poll cycle.
Expected: it is **not** re-posted for the same meeting, and recording never auto-starts. The menu-bar **Record …** button still works as a manual fallback.

- [ ] **Step 5: Commit (docs/notes only, if any)**

No code changes expected here. If verification surfaced a fix, return to the relevant task.

---

## Notes

- **Out of scope (per spec):** no re-prompting on ignore, no settings toggle to restore auto-start, no menu-bar banner (the menu bar already has manual Record buttons).
- **`REQUIREMENTS.md`:** if it documents auto-start as a behavior, update the relevant line to "prompts the user to start recording" as part of Task 3's commit. Check with `rg -ni "auto.?start|automatically" REQUIREMENTS.md` and edit any stale wording.
