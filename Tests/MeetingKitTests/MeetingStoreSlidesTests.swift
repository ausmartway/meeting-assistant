import Foundation
import Testing

@testable import MeetingKit

@Suite("MeetingStore slides")
struct MeetingStoreSlidesTests {

    /// A store rooted in a fresh temp directory, isolated per test.
    private func makeTempStore() throws -> MeetingStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "MeetingStoreSlidesTests-\(UUID().uuidString)", isDirectory: true)
        return try MeetingStore(root: tmp)
    }

    /// Write a bundle with both WAVs and one slide image.
    private func seed(_ store: MeetingStore, id: String) throws -> URL {
        let dir = try store.directory(for: id)
        try Data("mic".utf8).write(to: dir.appendingPathComponent("mic.wav"))
        try Data("sys".utf8).write(to: dir.appendingPathComponent("system.wav"))
        let slides = dir.appendingPathComponent("slides", isDirectory: true)
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        try Data("jpegbytes".utf8).write(to: slides.appendingPathComponent("slide-0030.jpg"))
        return dir
    }

    @Test("expiring audio keeps the captured slides (they follow the transcript, R26)")
    func expireMediaKeepsSlides() throws {
        let store = try makeTempStore()
        let dir = try seed(store, id: "m1")
        store.expireMedia(meetingID: "m1")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path) == false)
        #expect(
            fm.fileExists(
                atPath: dir.appendingPathComponent("slides/slide-0030.jpg").path) == true)
    }

    @Test("slide bytes count toward the bundle size shown in Storage")
    func slidesCountedInSize() throws {
        let store = try makeTempStore()
        _ = try seed(store, id: "m1")
        let withSlides = store.bundleSize(meetingID: "m1")
        store.expireMedia(meetingID: "m1")
        let slidesOnly = store.bundleSize(meetingID: "m1")
        #expect(slidesOnly > 0)  // the slide image is still counted after audio expiry
        #expect(withSlides > slidesOnly)
    }

    @Test("slidesDirectory points into the bundle without creating it")
    func slidesDirectoryDoesNotCreate() throws {
        let store = try makeTempStore()
        let url = store.slidesDirectory(for: "never-recorded")
        #expect(url.lastPathComponent == "slides")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        // And it must not have resurrected the bundle directory either.
        #expect(
            FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) == false)
    }

    @Test("deleting a meeting removes its slides too")
    func deleteRemovesSlides() throws {
        let store = try makeTempStore()
        let dir = try seed(store, id: "m1")
        try store.delete(meetingID: "m1")
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }
}
