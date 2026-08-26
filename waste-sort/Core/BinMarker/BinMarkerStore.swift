import Combine
import CoreGraphics
import Foundation
import os

/// Which detector decides whether a bin is open.
///
/// A single choice rather than two independent switches, because two switches would let both
/// run and leave "which one is actually gating deposits right now?" to be worked out from the
/// code — on site, in front of a bin that will not register a throw.
nonisolated enum BinOpennessSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// AprilTags mounted inside the bins. What shipped first, and still the default.
    case aprilTag
    /// Printed marker strips.
    case marker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aprilTag: return "AprilTags"
        case .marker: return "Marker strips"
        }
    }
}

@MainActor
final class BinMarkerStore: ObservableObject {
    static let shared = BinMarkerStore()

    @Published var source: BinOpennessSource {
        didSet { defaults.set(source.rawValue, forKey: Keys.source) }
    }
    /// What is printed on the strip. One choice, one sheet to print it from.
    @Published var kind: BinMarkerKind {
        didSet {
            defaults.set(kind.rawValue, forKey: Keys.kind)
            dashesToOpen = measuredDashesToOpen
        }
    }
    /// How short the printed dash row may be, and what that costs in dashes and time. Only
    /// `BinMarkerKind.dashes` leaves this open; the other two fix their own scan geometry.
    @Published var dashProfile: BinMarkerDashProfile {
        didSet {
            defaults.set(dashProfile.rawValue, forKey: Keys.dashProfile)
            dashesToOpen = measuredDashesToOpen
        }
    }
    /// How many printed dashes must clear the counter edge before the bin reads open.
    ///
    /// The number an operator actually feels, because it is what sets how far the drawer has
    /// to be pulled: at an 8 mm dash, each one is another 16 mm of travel.
    ///
    /// It follows the height and the shape whenever either changes, rather than being carried
    /// across to a setting it was never measured against — each combination has its own floor,
    /// below which the room starts producing rows on its own. Moving it by hand is allowed and
    /// is the point of having it; `measuredDashesToOpen` is what the measurement said, so the
    /// screen can show how far from it you are.
    @Published var dashesToOpen: Int {
        didSet { defaults.set(dashesToOpen, forKey: Keys.dashesToOpen) }
    }
    @Published var staleTimeout: Double {
        didSet { defaults.set(staleTimeout, forKey: Keys.staleTimeout) }
    }
    @Published var showDebugOverlay: Bool {
        didSet { defaults.set(showDebugOverlay, forKey: Keys.debug) }
    }

    /// Which detector reads the chosen kind. Derived, because the two are one decision on site.
    var style: BinMarkerStyle { kind.style }

    /// Slot → the chroma actually measured off the printed strip, under this room's light.
    ///
    /// The palette's built-in values describe ideal ink. What a printer lays down, a laminate
    /// reflects, and a camera's white balance reports is close but never equal, and the gap
    /// grows with cheap paper and warm lamps. Rather than widen the tolerance until anything
    /// colorful matches, the operator shows the app a strip once and the app writes down what
    /// it actually sees.
    @Published private(set) var calibration: [Int: CGPoint] {
        didSet { persistCalibration() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let source = "binMarker.source"
        static let kind = "binMarker.kind"
        static let dashProfile = "binMarker.dashProfile"
        static let dashesToOpen = "binMarker.dashesToOpen"
        static let staleTimeout = "binMarker.staleTimeout"
        static let debug = "binMarker.debug"
        static let calibration = "binMarker.calibration"
        /// Read once, to carry a device that was already set up across the change to one flat
        /// choice. Never written.
        static let legacyStyle = "binMarker.style"
        static let legacyDashShape = "binMarker.dashShape"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.source = defaults.string(forKey: Keys.source)
            .flatMap(BinOpennessSource.init(rawValue:)) ?? .aprilTag
        self.kind = defaults.string(forKey: Keys.kind)
            .flatMap(BinMarkerKind.init(rawValue:))
            ?? Self.migratedKind(from: defaults)
        self.staleTimeout = defaults.object(forKey: Keys.staleTimeout) != nil
            ? defaults.double(forKey: Keys.staleTimeout)
            : BinMarkerStateConfig.standard.staleTimeout
        let profile = defaults.string(forKey: Keys.dashProfile)
            .flatMap(BinMarkerDashProfile.init(rawValue:)) ?? .thin
        self.dashProfile = profile
        self.showDebugOverlay = defaults.bool(forKey: Keys.debug)
        // Property observers do not run during init, so the follow-the-profile rule in
        // `dashProfile.didSet` cannot seed this; the measured default is worked out here
        // instead, from the two settings that were just restored.
        let measured = Self.measuredDashesToOpen(
            profile: profile,
            shape: (defaults.string(forKey: Keys.kind)
                .flatMap(BinMarkerKind.init(rawValue:))
                ?? Self.migratedKind(from: defaults)).shape
        )
        self.dashesToOpen = defaults.object(forKey: Keys.dashesToOpen) != nil
            ? defaults.integer(forKey: Keys.dashesToOpen)
            : measured

        if let data = defaults.data(forKey: Keys.calibration),
           let decoded = try? JSONDecoder().decode([Int: [Double]].self, from: data) {
            self.calibration = decoded.compactMapValues { pair in
                pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
            }
        } else {
            self.calibration = [:]
        }
    }

    /// What a device set up before the style and the shape were folded into one should show.
    ///
    /// Colour has nowhere to land — it is no longer offered — so a device left on it comes
    /// back on dashes, which is what the site's own frames say it should have been on.
    private static func migratedKind(from defaults: UserDefaults) -> BinMarkerKind {
        let shape = defaults.string(forKey: Keys.legacyDashShape)
            .flatMap(BinMarkerDashShape.init(rawValue:)) ?? .plain
        switch defaults.string(forKey: Keys.legacyStyle).flatMap(BinMarkerStyle.init(rawValue:)) {
        case .mono: return .bars
        case .dashes: return shape == .chevron ? .chevrons : .dashes
        case .color, .none: return .dashes
        }
    }

    // MARK: - Palette

    /// The palette the detector should match against, with any calibration folded in.
    var inks: [BinMarkerInk] {
        BinMarkerSlot.all.map { slot in
            let ink = slot.ink
            guard let measured = calibration[slot.index] else { return ink }
            return BinMarkerInk(
                id: ink.id,
                displayName: ink.displayName,
                cb: Double(measured.x),
                cr: Double(measured.y),
                red: ink.red,
                green: ink.green,
                blue: ink.blue
            )
        }
    }

    var isCalibrated: Bool { !calibration.isEmpty }

    func calibrate(slot: Int, chroma: CGPoint) {
        guard BinMarkerSlot.withIndex(slot) != nil else { return }
        calibration[slot] = chroma
    }

    func clearCalibration() {
        calibration = [:]
    }

    // MARK: - Config

    var detectionConfig: BinMarkerConfig {
        var config = BinMarkerConfig.standard
        config.style = kind.style
        return config
    }

    var dashConfig: BinMarkerDashConfig {
        var config = BinMarkerDashConfig.standard
        config.profile = dashProfile
        config.shape = kind.shape
        // Last, because setting either of the two above recomputes `minRuns` from what they
        // were measured to need. The slider is the operator overruling that, so it goes on top.
        config.minRuns = BinMarkerDashConfig.runs(forDashes: dashesToOpen)
        return config
    }

    /// What the current height and shape were measured to need, whatever the slider is set to.
    var measuredDashesToOpen: Int {
        Self.measuredDashesToOpen(profile: dashProfile, shape: kind.shape)
    }

    private static func measuredDashesToOpen(
        profile: BinMarkerDashProfile,
        shape: BinMarkerDashShape
    ) -> Int {
        var config = BinMarkerDashConfig.standard
        config.profile = profile
        config.shape = shape
        return config.dashesNeeded
    }

    var stateConfig: BinMarkerStateConfig {
        BinMarkerStateConfig(staleTimeout: staleTimeout)
    }

    // MARK: - Persistence

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            AppLog.persistence.error("Failed to encode marker setting for \(key, privacy: .public)")
            return
        }
        defaults.set(data, forKey: key)
    }

    private func persistCalibration() {
        let encodable = calibration.mapValues { [Double($0.x), Double($0.y)] }
        persist(encodable, forKey: Keys.calibration)
    }
}
