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
    @Published var style: BinMarkerStyle {
        didSet { defaults.set(style.rawValue, forKey: Keys.style) }
    }
    @Published var staleTimeout: Double {
        didSet { defaults.set(staleTimeout, forKey: Keys.staleTimeout) }
    }
    @Published var showDebugOverlay: Bool {
        didSet { defaults.set(showDebugOverlay, forKey: Keys.debug) }
    }
    /// Zone id → marker slot.
    @Published var bindings: [UUID: Int] {
        didSet { persist(bindings, forKey: Keys.bindings) }
    }
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
        static let style = "binMarker.style"
        static let staleTimeout = "binMarker.staleTimeout"
        static let debug = "binMarker.debug"
        static let bindings = "binMarker.bindings"
        static let calibration = "binMarker.calibration"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.source = defaults.string(forKey: Keys.source)
            .flatMap(BinOpennessSource.init(rawValue:)) ?? .aprilTag
        self.style = defaults.string(forKey: Keys.style)
            .flatMap(BinMarkerStyle.init(rawValue:)) ?? .color
        self.staleTimeout = defaults.object(forKey: Keys.staleTimeout) != nil
            ? defaults.double(forKey: Keys.staleTimeout)
            : BinMarkerStateConfig.standard.staleTimeout
        self.showDebugOverlay = defaults.bool(forKey: Keys.debug)

        if let data = defaults.data(forKey: Keys.bindings),
           let decoded = try? JSONDecoder().decode([UUID: Int].self, from: data) {
            self.bindings = decoded
        } else {
            self.bindings = [:]
        }
        if let data = defaults.data(forKey: Keys.calibration),
           let decoded = try? JSONDecoder().decode([Int: [Double]].self, from: data) {
            self.calibration = decoded.compactMapValues { pair in
                pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
            }
        } else {
            self.calibration = [:]
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

    // MARK: - Bindings

    func slot(for zoneID: UUID, defaultIndex: Int) -> Int {
        bindings[zoneID] ?? defaultIndex
    }

    func setSlot(_ slot: Int, for zoneID: UUID) {
        bindings[zoneID] = slot
    }

    func prune(toActiveZoneIDs activeZoneIDs: Set<UUID>) {
        let kept = bindings.filter { activeZoneIDs.contains($0.key) }
        if kept.count != bindings.count { bindings = kept }
    }

    // MARK: - Config

    var detectionConfig: BinMarkerConfig {
        var config = BinMarkerConfig.standard
        config.style = style
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
