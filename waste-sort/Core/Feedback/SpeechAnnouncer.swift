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
final class SpeechAnnouncer: SpeechSynthesizing {
    static let shared = SpeechAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    /// Serializes utterances so rapid successive deposits queue cleanly.
    private let lock = NSLock()
    private var sessionConfigured = false

    init() {}

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        configureAudioSessionIfNeededLocked()
        // Interrupt rather than queue: a stale instruction ("organic") seconds
        // after the item was sorted is worse than silence.
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = 1.0
        synthesizer.speak(utterance)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        synthesizer.stopSpeaking(at: .immediate)
        lock.unlock()
    }

    private func configureAudioSessionIfNeededLocked() {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)
            sessionConfigured = true
        } catch {
            AppLog.ui.error("Audio session config failed - voice guidance silent: \(error.localizedDescription)")
        }
    }
}

/// User-facing phrases for voice guidance, kept pure for testing.
nonisolated enum GuidancePhrases {
    /// Natural spoken form of a bin display name ("ORGANIC" -> "Organic bin").
    static func depositConfirmation(displayName: String) -> String {
        let word = displayName.lowercased().capitalized
        return "\(word) bin"
    }
}
