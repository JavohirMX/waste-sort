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

/// Default when no lid source is installed (tests that do not care about lids):
/// every bin reads open. Production always installs `FrameBinOpenState`, which
/// is evidence-based, so this type never ships behavior — it only preserves the
/// pre-lid semantics where nothing gates the detector.
nonisolated struct AlwaysOpenBins: BinOpenStateProviding {
    func isOpen(binID: String) -> Bool { true }
}

/// One-frame snapshot of AprilTag lid state, keyed the way `ZoneDepositDetector`
/// asks: by `BinGuide` id. Evidence-based and fail-closed: a bin reads open only
/// when its zone's tag is currently detected with an `.open` lid. `.closed`,
/// `.unknown`, and an empty frame (AprilTag off, or no tags in view) all read as
/// **not** open — without lid evidence there are no credited deposits and no
/// throw feedback, which is what keeps a kiosk pointed at a wall from narrating
/// wrong-bin throws.
nonisolated struct FrameBinOpenState: BinOpenStateProviding {
    let openBinIDs: Set<String>

    init(tagFrame: AprilTagStatusFrame, zones: [DropZone]) {
        openBinIDs = Set(
            zones.filter { tagFrame.openZoneIDs.contains($0.id) }.map(\.binID)
        )
    }

    func isOpen(binID: String) -> Bool { openBinIDs.contains(binID) }
}
