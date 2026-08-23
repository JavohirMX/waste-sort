import Foundation
import os

/// Central os.Logger facade so failures are observable without print() noise.
/// Categories map to subsystem areas; use `AppLog.ui`, `.pipeline`, `.recording`,
/// `.persistence`, `.vision` instead of constructing loggers ad hoc.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.mohamedmorad.sortla"

    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let vision = Logger(subsystem: subsystem, category: "vision")
}
