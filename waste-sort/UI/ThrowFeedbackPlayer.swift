import AVFoundation
import Foundation
import os

/// Plays the one-shot correct / incorrect throw clips. Uses `.playback` so a kiosk iPad
/// still sounds when the silent switch is on.
@MainActor
final class ThrowFeedbackPlayer {
    static let shared = ThrowFeedbackPlayer()

    private var player: AVAudioPlayer?
    private var didConfigureSession = false
    private var pendingURL: URL?
    private var configureTask: Task<Void, Never>?

    func play(correct: Bool) {
        let name = correct ? "feedback-correct" : "feedback-incorrect"
        guard let url = Self.resourceURL(named: name) else { return }
        if didConfigureSession {
            startPlayback(url: url)
            return
        }
        pendingURL = url
        guard configureTask == nil else { return }
        configureTask = Task { @MainActor in
            await self.configureSessionIfNeeded()
            if self.didConfigureSession, let pendingURL = self.pendingURL {
                self.startPlayback(url: pendingURL)
            }
            self.pendingURL = nil
            self.configureTask = nil
        }
    }

    private func startPlayback(url: URL) {
        player?.stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            AppLog.ui.error("Throw feedback playback failed: \(error.localizedDescription)")
        }
    }

    private func configureSessionIfNeeded() async {
        guard !didConfigureSession else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try await Self.activateOffMain()
            didConfigureSession = true
        } catch {
            AppLog.ui.error("Throw feedback audio session failed: \(error.localizedDescription)")
        }
    }

    /// `activate(options:)` is watchOS-only (`API_UNAVAILABLE(ios)` on the iOS 26.5 SDK).
    /// Hopping `setActive` off the main thread is the iOS equivalent of that async API
    /// and is what the Thread Performance Checker is asking for.
    nonisolated private static func activateOffMain() async throws {
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSession.sharedInstance().setActive(true)
        }.value
    }

    private static func resourceURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp3")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Resources/Sounds")
    }
}
