# Prompt-to-record instead of auto-start

**Date:** 2026-06-17
**Status:** Approved, pending implementation

## Problem

Today the app silently auto-starts capture the moment a meeting is detected.
`AppState.tick()` (polling every 30s) finds a meeting where
`MeetingDetector.shouldAutoStart` is true and immediately calls
`notifyAndStart(_:)`, which posts a passive "Recording started" notification and
begins recording — the user never consents.

We want recording to start only after the user explicitly accepts a prompt.

## Decisions

- **Mechanism:** an actionable system notification with a **"Start Recording"**
  action button. Capture begins only when the user clicks it.
- **Auto-start is removed entirely.** No setting toggle; detected meetings always
  prompt.
- **Prompt once per meeting.** Reuse the existing `notifiedMeetingIDs` dedup set.
  If the banner is missed, the user can still start manually from the menu bar.
- **Delegate ownership:** a small dedicated `NotificationCoordinator` type owns
  category registration and `UNUserNotificationCenterDelegate` conformance,
  holding a weak reference back into `AppState`. Keeps `AppState` focused.

## Behavior

Detection is unchanged (`MeetingDetector.shouldAutoStart`: within the start grace
window, not ended, client app running). When detected:

1. `AppState.tick()` calls `promptToRecord(_:)` instead of `notifyAndStart(_:)`.
   No capture is started here.
2. `promptToRecord(_:)` posts an actionable notification:
   - title: "Start recording?"
   - body: the meeting name
   - `categoryIdentifier`: `"MEETING_DETECTED"`
   - `userInfo`: the meeting `id`, plus title and provider (for the late-click
     fallback below).
   - Still guarded by the `notifiedMeetingIDs` dedup set and the "no active
     recording" check.
3. User clicks **Start Recording** → the delegate resolves the meeting and calls
   `startCapture(for:)`.
4. The existing "Recording started" notification now fires *after* acceptance, so
   it is finally accurate.

## Components

### `NotificationCoordinator` (new)

- Conforms to `UNUserNotificationCenterDelegate`; set as
  `UNUserNotificationCenter.current().delegate` at startup.
- Registers a `UNNotificationCategory("MEETING_DETECTED")` containing one
  `UNNotificationAction("START_RECORDING", "Start Recording", [.foreground])`.
- `userNotificationCenter(_:didReceive:)` — on `START_RECORDING`, reads the
  meeting id from `userInfo`, resolves the meeting (see fallback), and calls into
  `AppState.startCapture(for:)` on the MainActor.
- `userNotificationCenter(_:willPresent:)` — returns `[.banner, .sound]` so the
  prompt shows even when the app is foreground.
- Holds a `weak` reference to `AppState`.

### `AppState`

- `tick()` (AppState.swift:217–226): the per-meeting branch calls
  `promptToRecord(_:)` instead of `notifyAndStart(_:)`.
- `notifyAndStart(_:)` → renamed/repurposed as `promptToRecord(_:)` (~256–263):
  posts the actionable notification with `userInfo`; keeps dedup + no-active-
  recording guards; does **not** start capture.
- Owns/creates the `NotificationCoordinator` and wires the weak back-reference.
- `startCapture(for:)` is unchanged (already guards `recording == nil`).

### Meeting resolution helper (pure, testable)

Extract the "resolve a Meeting from notification `userInfo`" mapping into a pure
function: given the `userInfo` dictionary and the current `upcomingMeetings`
list, return the matching `Meeting`, or reconstruct an ad-hoc `Meeting` from the
stored title/provider when the meeting is no longer in the list. Unit-tested.

## Edge cases

- **Late click after meeting left the upcoming list:** reconstruct an ad-hoc
  `Meeting` from `userInfo` (title + provider) so recording still works.
- **Already recording when the action fires:** `startCapture` guards
  `recording == nil` → no-op.
- **Notifications not granted:** `postNotification` already early-returns; the
  user can still start from the menu bar (unchanged).

## Testing

- The notification + delegate path requires real system access → verified by
  running the app, consistent with the project's "integrations aren't unit
  tested" rule.
- `MeetingDetector.shouldAutoStart` is unchanged and already covered.
- The new pure meeting-resolution helper gets a unit test (swift-testing).

## Out of scope

- Re-prompting / reminders if the notification is ignored (decided: once per
  meeting).
- A settings toggle to restore auto-start.
- Menu-bar banner UI (the menu bar already has manual Record buttons).
