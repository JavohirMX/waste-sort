import Foundation

enum SessionFileNamer {
    /// Local-time prefix shared by a session's CSV and annotated movie, e.g. `Sortla-2026-08-14-150932`.
    static func prefix(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Sortla-\(formatter.string(from: date))"
    }
}
