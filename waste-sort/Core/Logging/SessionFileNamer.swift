import Foundation

enum SessionFileNamer {
    /// Local-time prefix shared by a session's CSV and annotated movie, e.g. `Sortla-2026-08-14-150932`.
    static func prefix(for date: Date) -> String {
        "Sortla-\(TimestampFormatters.fileStamp.string(from: date))"
    }
}
