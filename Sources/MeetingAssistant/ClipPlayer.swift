import AVFoundation
import Foundation

/// Plays one transcript-line clip at a time (speaker verification, R27).
/// Starting a new clip stops the current one; the view highlights whichever
/// turn id is playing. Failures just reset to stopped — playback is auxiliary.
@MainActor
final class ClipPlayer: ObservableObject {
    @Published private(set) var playingTurnID: Int?

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(url: URL, from start: TimeInterval, to end: TimeInterval, turnID: Int) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url), end > start else { return }
        self.player = player
        player.currentTime = start
        guard player.play() else {
            self.player = nil
            return
        }
        playingTurnID = turnID
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((end - start) * 1_000_000_000))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingTurnID = nil
    }
}
