import Combine
import Foundation

/// Coordinates the "Preview" hand-off from Bin Settings to the live camera screen.
/// Activating it collapses Stats/Bin Settings so the real, already-running camera
/// feed shows through underneath, rather than opening a second capture session.
final class BinPreviewCoordinator: ObservableObject {
    static let shared = BinPreviewCoordinator()

    @Published var isActive = false
    /// Set when Preview was entered from inside Bin Settings, so tapping "Settings"
    /// on the preview bar can reopen it instead of just landing back on Stats.
    @Published var returnsToBinSettings = false

    private init() {}
}
