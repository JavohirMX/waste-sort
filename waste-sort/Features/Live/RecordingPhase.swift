import Foundation

enum RecordingPhase: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case saving
}

/// Lock-guarded mirror of `RecordingController.phase`.
///
/// The YOLO inference queue calls into the live pipeline on every frame and must
/// know whether a recording is rolling without hopping to the main actor.
/// This mirror is updated whenever the published phase changes and is safe to
/// read from any thread.
final class RecordingPhaseMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RecordingPhase = .idle

    var current: RecordingPhase {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: RecordingPhase) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
