/// The marker half of the lid signal, grouped so adding to it does not widen four
/// initialisers every time.
struct BinOpennessInputs: Equatable, Sendable {
    var source: BinOpennessSource = .aprilTag
    /// What is printed on the strips. Carries both the detection style and the dash shape,
    /// because on site they are not two decisions.
    var markerKind: BinMarkerKind = .dashes
    var markerDashProfile: BinMarkerDashProfile = .thin
    /// Printed dashes that must clear the counter edge before the bin reads open.
    var markerDashesToOpen: Int = BinMarkerDashProfile.thin.dashesNeeded
    var markerStaleTimeout: Double = BinMarkerStateConfig.standard.staleTimeout
    /// Palette with any on-site calibration already folded in.
    var markerInks: [BinMarkerInk] = BinMarkerInk.all
    var markerDebugOverlay: Bool = false

    var usesMarkers: Bool { source == .marker }
}
