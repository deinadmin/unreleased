import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class VersionPreviewPlayer {
    private(set) var currentVersionID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    func toggle(versionID: UUID, url: URL) throws {
        if currentVersionID == versionID, let audioPlayer {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                isPlaying = false
            } else {
                audioPlayer.play()
                isPlaying = audioPlayer.isPlaying
                startTimer()
            }
            return
        }

        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        audioPlayer = player
        currentVersionID = versionID
        duration = player.duration
        currentTime = 0
        player.play()
        isPlaying = player.isPlaying
        startTimer()
    }

    func seek(to time: TimeInterval) {
        guard let audioPlayer else { return }
        let clamped = min(max(time, 0), duration)
        audioPlayer.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        currentVersionID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.currentTime = audioPlayer.currentTime
                self.isPlaying = audioPlayer.isPlaying
                if !audioPlayer.isPlaying, audioPlayer.currentTime >= audioPlayer.duration - 0.05 {
                    self.currentTime = audioPlayer.duration
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
