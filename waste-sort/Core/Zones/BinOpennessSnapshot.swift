import Foundation

/// One frame's bin-openness state, from whichever detector is switched on.
///
/// Both frames travel together rather than one replacing the other, because the debug overlays
/// are how the two are compared on site — and comparing them means being able to see the idle
/// one report nothing while the live one gates deposits.
///
/// `source` is the only thing that decides which of them actually gated this frame. Anything
/// reading these frames to explain a deposit must check it first.
nonisolated struct BinOpennessSnapshot: Equatable, Sendable {
    var source: BinOpennessSource = .aprilTag
    var tag = AprilTagStatusFrame()
    var marker = BinMarkerStatusFrame()

    init(
        source: BinOpennessSource = .aprilTag,
        tag: AprilTagStatusFrame = AprilTagStatusFrame(),
        marker: BinMarkerStatusFrame = BinMarkerStatusFrame()
    ) {
        self.source = source
        self.tag = tag
        self.marker = marker
    }

    /// The gate `ZoneDepositDetector` should run with this frame.
    func openState(zones: [DropZone]) -> FrameBinOpenState {
        switch source {
        case .aprilTag: return FrameBinOpenState(tagFrame: tag, zones: zones)
        case .marker: return FrameBinOpenState(markerFrame: marker, zones: zones)
        }
    }
}
