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
        didSet { defaults.set(kind.rawValue, forKey: Keys.kind) }
    }
    /// How short the printed dash row may be, and what that costs in dashes and time. Only
    /// `BinMarkerKind.dashes` leaves this open; the other two fix their own scan geometry.
    @Published var dashProfile: BinMarkerDashProfile {
        didSet { defaults.set(dashProfile.rawValue, forKey: Keys.dashProfile) }
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
        self.dashProfile = defaults.string(forKey: Keys.dashProfile)
            .flatMap(BinMarkerDashProfile.init(rawValue:)) ?? .thin
        self.showDebugOverlay = defaults.bool(forKey: Keys.debug)

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
        return config
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
