import AVFoundation
import Foundation

/// Plays the one-shot correct / incorrect throw clips. Uses `.playback` so a kiosk iPad
/// still sounds when the silent switch is on.
@MainActor
final class ThrowFeedbackPlayer {
    static let shared = ThrowFeedbackPlayer()

    private var player: AVAudioPlayer?
    private var didConfigureSession = false

    func play(correct: Bool) {
        configureSessionIfNeeded()
        let name = correct ? "feedback-correct" : "feedback-incorrect"
        guard let url = Self.resourceURL(named: name) else { return }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private static func resourceURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp3")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Resources/Sounds")
    }
}
