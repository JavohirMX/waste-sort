import Foundation

/// Whether the lid of a physical bin is open right now.
///
/// Two rules in `ZoneDepositDetector` hang off this signal, and they pull in opposite
/// directions on purpose:
///
/// - an item can only be *thrown into* a bin that is open, so a deposit is credited only
///   when the target bin was open around the moment the item vanished;
/// - an item the model first finds already sitting inside an **open** bin is most likely
///   waste that is already in there, so it is disqualified. Inside a **closed** bin it
///   cannot be bin contents — it is something resting on the shut lid, and it stays
///   eligible to be thrown later.
nonisolated protocol BinOpenStateProviding {
    /// - Parameter binID: a `BinGuide` id — `organic`, `residual`, or `clean_inorganic`.
    func isOpen(binID: String) -> Bool
}

/// **Placeholder.** Every bin always reads open, which reproduces exactly the behaviour
/// that shipped before the lid signal existed.
///
/// Real lid detection lands separately. When it does, the only thing that changes is the
/// provider handed to `ZoneDepositDetector` — every rule that depends on the lid is
/// already written against the protocol above.
nonisolated struct AlwaysOpenBins: BinOpenStateProviding {
    func isOpen(binID: String) -> Bool { true }
}
