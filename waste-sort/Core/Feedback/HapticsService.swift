import CoreHaptics
import os
import UIKit

/// Centralized haptic language, replacing ad-hoc UIImpactFeedbackGenerator calls.
///
/// Uses CoreHaptics where available so different outcomes feel different:
/// a correct deposit gets a pattern shaped by its bin, a wrong-bin drop gets a
/// warning buzz. Falls back to UIFeedbackGenerator semantics elsewhere.
final class HapticsService {
    static let shared = HapticsService()

    enum FeedbackEvent {
        /// Correct deposit into a zone; pattern varies by bin identity.
        case depositCorrect(binID: String)
        /// Item landed in a zone that does not match its class.
        case depositIncorrect
        case lightTap
        case mediumImpact
    }

    private let supportsHaptics: Bool
    private var engine: CHHapticEngine?

    private init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else { return }
        engine = try? CHHapticEngine()
        // Backgrounding stops the engine; restart transparently when needed again.
        engine?.resetHandler = { [weak self] in
            try? self?.engine?.start()
        }
        try? engine?.start()
    }

    func fire(_ event: FeedbackEvent) {
        guard supportsHaptics, let pattern = Self.pattern(for: event), let engine else {
            fallback(event)
            return
        }
        do {
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            AppLog.ui.error("Haptic playback failed: \(error.localizedDescription)")
            fallback(event)
        }
    }

    // MARK: - Patterns

    private static func pattern(for event: FeedbackEvent) -> CHHapticPattern? {
        let events: [CHHapticEvent]
        switch event {
        case .depositCorrect(let binID):
            // Organic: one soft rounded thud. Recyclable: rising double tick.
            // Residual/other: firm single knock.
            switch binID {
            case BinGuide.organic.id:
                events = [continuous(at: 0.0, duration: 0.16, intensity: 0.65, sharpness: 0.25)]
            case BinGuide.cleanInorganic.id:
                events = [
                    transient(at: 0.0, intensity: 0.45, sharpness: 0.6),
                    transient(at: 0.12, intensity: 0.75, sharpness: 0.8)
                ]
            default:
                events = [transient(at: 0.0, intensity: 0.6, sharpness: 0.4)]
            }
        case .depositIncorrect:
            // Warning: three evenly spaced buzzes.
            events = (0..<3).map { transient(at: Double($0) * 0.11, intensity: 0.85, sharpness: 0.95) }
        case .lightTap:
            events = [transient(at: 0.0, intensity: 0.4, sharpness: 0.7)]
        case .mediumImpact:
            events = [transient(at: 0.0, intensity: 0.7, sharpness: 0.5)]
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    private static func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }

    private static func continuous(
        at time: TimeInterval,
        duration: TimeInterval,
        intensity: Float,
        sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time,
            duration: duration
        )
    }

    private func fallback(_ event: FeedbackEvent) {
        switch event {
        case .depositCorrect, .depositIncorrect, .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .lightTap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
