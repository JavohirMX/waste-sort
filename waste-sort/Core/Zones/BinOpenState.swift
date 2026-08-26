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

/// Default when AprilTag is off, and the lid signal for tests that do not care about it:
/// every bin reads open, which is the behaviour that shipped before the lid existed.
nonisolated struct AlwaysOpenBins: BinOpenStateProviding {
    func isOpen(binID: String) -> Bool { true }
}

/// One-frame snapshot of AprilTag lid state, keyed the way `ZoneDepositDetector` asks:
/// by `BinGuide` id. Only `.closed` zones count as shut; `.open` and `.unknown` (and an
/// empty frame when tags are disabled) all read as open.
nonisolated struct FrameBinOpenState: BinOpenStateProviding {
    let closedBinIDs: Set<String>

    init(tagFrame: AprilTagStatusFrame, zones: [DropZone]) {
        self.init(closedZoneIDs: tagFrame.closedZoneIDs, zones: zones)
    }

    /// The same snapshot taken from printed marker strips instead of AprilTags.
    ///
    /// Two sources, one gate: `ZoneDepositDetector` is not told which detector is running,
    /// and must not be — swapping the lid signal is a settings choice, not a code path.
    init(markerFrame: BinMarkerStatusFrame, zones: [DropZone]) {
        self.init(closedZoneIDs: markerFrame.closedZoneIDs, zones: zones)
    }

    private init(closedZoneIDs: Set<UUID>, zones: [DropZone]) {
        closedBinIDs = Set(
            zones.filter { closedZoneIDs.contains($0.id) }.map(\.binID)
        )
    }

    func isOpen(binID: String) -> Bool { !closedBinIDs.contains(binID) }
}
