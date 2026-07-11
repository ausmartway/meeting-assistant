import AVFoundation
import Foundation
import os

/// Plays one transcript-line clip at a time (speaker verification, R27).
/// Starting a new clip stops the current one; the view highlights whichever
/// turn id is playing. Failures just reset to stopped — playback is auxiliary,
/// but they ARE logged so a silent play button is diagnosable in Console.
@MainActor
final class ClipPlayer: ObservableObject {
    private static let log = Logger(subsystem: "MeetingAssistant", category: "clipplayer")

    @Published private(set) var playingTurnID: Int?

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(url: URL, from start: TimeInterval, to end: TimeInterval, turnID: Int) {
        stop()
        Self.log.info(
            "play turn \(turnID) \(url.lastPathComponent, privacy: .public) [\(start, privacy: .public)-\(end, privacy: .public)]"
        )
        guard end > start else {
            Self.log.error("degenerate clip window; not playing")
            return
        }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            Self.log.error(
                "AVAudioPlayer init failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.player = player
        player.currentTime = start
        guard player.play() else {
            Self.log.error("play() returned false")
            self.player = nil
            return
        }
        Self.log.info(
            "playing — duration \(player.duration, privacy: .public), currentTime \(player.currentTime, privacy: .public)"
        )
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
