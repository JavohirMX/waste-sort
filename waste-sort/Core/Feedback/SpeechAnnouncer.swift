import AVFoundation
import Foundation
import os

/// Abstraction over speech output so callers can be tested without audio.
nonisolated protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String)
    func stop()
}

/// Speaks deposit confirmations for hands-free kiosk operation.
///
/// Restores the FirstMVP concept: an operator standing back from the station
/// hears which bin to use even when the HUD is hard to see. Audio session is
/// configured lazily on first utterance (.playback + .duckOthers) so spoken
/// cues cut through ambient noise without permanently hijacking audio.
final class SpeechAnnouncer: SpeechSynthesizing, @unchecked Sendable {
    static let shared = SpeechAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    /// Serializes utterances so rapid successive deposits queue cleanly.
    private let lock = NSLock()
    private var sessionConfigured = false
    private var pendingText: String?
    private var configureTask: Task<Void, Never>?

    init() {}

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if sessionConfigured {
            emitLocked(text)
            return
        }
        pendingText = text
        guard configureTask == nil else { return }
        configureTask = Task { @MainActor in
            switch await Self.configureAudioSession() {
            case .success:
                self.finishConfigure(success: true)
            case .failure(let error):
                AppLog.ui.error(
                    "Audio session config failed - voice guidance silent: \(error.localizedDescription)"
                )
                self.finishConfigure(success: false)
            }
        }
    }

    func stop() {
        lock.lock()
        pendingText = nil
        synthesizer.stopSpeaking(at: .immediate)
        lock.unlock()
    }

    /// Must not be `async`: `NSLock.lock()` is unavailable from asynchronous contexts.
    private func finishConfigure(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        configureTask = nil
        let pending = pendingText
        pendingText = nil
        guard success else { return }
        sessionConfigured = true
        if let pending {
            emitLocked(pending)
        }
    }

    /// Interrupt rather than queue: a stale instruction ("organic") seconds
    /// after the item was sorted is worse than silence.
    private func emitLocked(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    nonisolated private static func configureAudioSession() async -> Result<Void, Error> {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try await activateOffMain()
            return .success(())
        } catch {
            return .failure(error)
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
}

/// User-facing phrases for voice guidance, kept pure for testing.
nonisolated enum GuidancePhrases {
    /// Natural spoken form of a bin display name ("ORGANIC" -> "Organic bin").
    static func depositConfirmation(displayName: String) -> String {
        let word = displayName.lowercased().capitalized
        return "\(word) bin"
    }

    /// Spoken form for a fallback-routed deposit: honest about the uncertainty while
    /// still confirming the safe destination.
    static func uncertainDepositConfirmation(displayName: String) -> String {
        "\(depositConfirmation(displayName: displayName)). Not sure, so residual is safest"
    }
}
