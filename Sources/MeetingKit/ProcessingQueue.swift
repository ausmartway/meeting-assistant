import Foundation

/// A serial queue of meetings awaiting transcription, so a new meeting can be
/// recorded while earlier ones are still being processed. Pure value type (dedup
/// by meeting id) so the queue semantics are unit-testable independently of the
/// `@MainActor` coordinator that drains it.
///
/// At most one meeting is `current` (being transcribed) at a time; the rest wait
/// in `pending` in FIFO order. Transcription is GPU-heavy and shares one model,
/// so processing stays serial even though recording runs concurrently.
public struct ProcessingQueue: Equatable, Sendable {
    /// The meeting currently being transcribed, if any.
    public private(set) var current: Meeting?
    /// Meetings waiting their turn, oldest first.
    public private(set) var pending: [Meeting]

    public init(current: Meeting? = nil, pending: [Meeting] = []) {
        self.current = current
        self.pending = pending
    }

    /// Nothing recording-adjacent is happening.
    public var isEmpty: Bool { current == nil && pending.isEmpty }

    /// How many meetings are waiting behind the one being transcribed.
    public var pendingCount: Int { pending.count }

    /// True if the meeting is currently being transcribed or is waiting to be.
    public func contains(_ meetingID: String) -> Bool {
        current?.id == meetingID || pending.contains { $0.id == meetingID }
    }

    /// Add a meeting to the back of the queue, unless it is already current or
    /// already pending (dedup by id — re-processing the same meeting twice is a
    /// no-op while it's in flight).
    public mutating func enqueue(_ meeting: Meeting) {
        guard !contains(meeting.id) else { return }
        pending.append(meeting)
    }

    /// Promote the next pending meeting to `current` and return it, but only when
    /// nothing is currently being processed. Returns nil if a meeting is already
    /// in flight or the queue is empty.
    public mutating func startNext() -> Meeting? {
        guard current == nil, !pending.isEmpty else { return nil }
        current = pending.removeFirst()
        return current
    }

    /// Mark the in-flight meeting done, freeing the slot for `startNext()`.
    public mutating func finishCurrent() {
        current = nil
    }
}
