import Testing
import Foundation
@testable import MeetingKit

@Suite("ProcessingQueue")
struct ProcessingQueueTests {

    private func meeting(_ id: String) -> Meeting {
        Meeting(id: id, title: "M-\(id)", startDate: Date(), endDate: Date(), provider: nil, joinURL: nil)
    }

    @Test("enqueue then startNext promotes FIFO, one at a time")
    func fifoSerial() {
        var q = ProcessingQueue()
        q.enqueue(meeting("a"))
        q.enqueue(meeting("b"))
        #expect(q.pendingCount == 2)

        let first = q.startNext()
        #expect(first?.id == "a")
        #expect(q.current?.id == "a")
        #expect(q.pendingCount == 1)

        // Nothing else starts while one is in flight.
        #expect(q.startNext() == nil)
        #expect(q.current?.id == "a")

        q.finishCurrent()
        #expect(q.current == nil)
        let second = q.startNext()
        #expect(second?.id == "b")
        #expect(q.isEmpty == false)
        q.finishCurrent()
        #expect(q.isEmpty)
    }

    @Test("enqueue dedupes by id against both pending and current")
    func dedup() {
        var q = ProcessingQueue()
        q.enqueue(meeting("a"))
        q.enqueue(meeting("a"))           // dup pending → ignored
        #expect(q.pendingCount == 1)

        _ = q.startNext()                 // "a" now current
        q.enqueue(meeting("a"))           // dup current → ignored
        #expect(q.pendingCount == 0)
        #expect(q.current?.id == "a")
    }

    @Test("contains reflects current and pending")
    func contains() {
        var q = ProcessingQueue()
        q.enqueue(meeting("a"))
        q.enqueue(meeting("b"))
        _ = q.startNext()                 // a current, b pending
        #expect(q.contains("a"))
        #expect(q.contains("b"))
        #expect(!q.contains("c"))
    }

    @Test("startNext on empty queue returns nil and stays empty")
    func emptyStart() {
        var q = ProcessingQueue()
        #expect(q.startNext() == nil)
        #expect(q.isEmpty)
    }
}
