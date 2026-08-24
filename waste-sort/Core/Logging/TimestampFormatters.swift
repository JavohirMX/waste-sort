import Foundation

/// Cached date formatters for hot paths (overlay rendering, session naming).
///
/// Constructing a `DateFormatter` costs milliseconds - doing it per composited
/// frame (~30 fps) dominated overlay-render profiling. Instances are configured
/// once; `DateFormatter` is documented thread-safe for formatting on iOS 7+.
nonisolated enum TimestampFormatters {
    /// Overlay badge clock, e.g. `14:03:22.187`.
    static let overlayClock = make(format: "HH:mm:ss.SSS")

    /// Local-time stamp used in session file prefixes, e.g. `2026-08-14-150932`.
    static let fileStamp = make(format: "yyyy-MM-dd-HHmmss")

    private static func make(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
