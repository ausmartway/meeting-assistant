import Testing
import CoreGraphics
@testable import MeetingKit

@Suite("SpeakerSampler.dominantTile")
struct SpeakerSamplerDominantTileTests {

    private func rect(_ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: w, height: h)
    }

    @Test("no tiles → nil")
    func empty() {
        #expect(SpeakerSampler.dominantTile([]) == nil)
    }

    @Test("a single tile is dominant (1-on-1 / speaker view)")
    func singleTile() {
        let r = rect(1, 1)
        #expect(SpeakerSampler.dominantTile([r]) == r)
    }

    @Test("a clearly-largest tile wins over a small self-view PiP")
    func clearlyLargest() {
        let main = rect(1.0, 1.0)            // full-frame remote
        let pip = rect(0.2, 0.2)             // small self-view
        #expect(SpeakerSampler.dominantTile([pip, main]) == main)
    }

    @Test("a gallery of similar-sized tiles is ambiguous → nil")
    func equalGallery() {
        let tiles = [rect(0.5, 0.5), rect(0.5, 0.5), rect(0.5, 0.48), rect(0.49, 0.5)]
        #expect(SpeakerSampler.dominantTile(tiles) == nil)
    }
}

@Suite("SpeakerSampler.bestName")
struct SpeakerSamplerTests {

    @Test("prefers a full name over UI control words")
    func prefersNameOverControls() {
        let lines = ["Mute", "Alice Johnson", "Stop Video"]
        #expect(SpeakerSampler.bestName(from: lines) == "Alice Johnson")
    }

    @Test("rejects lines that are mostly non-letters")
    func rejectsNonLetterLines() {
        let lines = ["12:34", "98%", "----"]
        #expect(SpeakerSampler.bestName(from: lines) == nil)
    }

    @Test("filters out the 'You' self-label")
    func filtersYou() {
        let lines = ["You"]
        #expect(SpeakerSampler.bestName(from: lines) == nil)
    }

    @Test("returns nil for empty input")
    func emptyInput() {
        #expect(SpeakerSampler.bestName(from: []) == nil)
    }

    @Test("picks a Chinese name over Chinese UI control words")
    func picksChineseName() {
        let lines = ["静音", "王伟", "停止视频"]
        #expect(SpeakerSampler.bestName(from: lines) == "王伟")
    }
}
