import Combine
import CoreGraphics
import Foundation

enum ZoneConfig {
    static let defaultDwellFrames = 3
    static let dwellRange = 1...15
    /// Long enough to cover the dropouts seen in practice, short enough that a real throw
    /// still lands in the log while the person is standing there.
    static let defaultReacquireGrace = 1.4
    static let reacquireGraceRange = 0.0...3.0
}

/// Persisted drop zones plus the transient state the live editor needs.
@MainActor
final class ZoneStore: ObservableObject {
    static let shared = ZoneStore()

    @Published private(set) var zones: [DropZone] {
        didSet { persistZones() }
    }

    /// How many detected in-zone frames arm an object.
    @Published var dwellFrames: Int {
        didSet { defaults.set(dwellFrames, forKey: Keys.dwellFrames) }
    }

    /// Seconds a vanished object is given to reappear before it is judged.
    @Published var reacquireGrace: Double {
        didSet { defaults.set(reacquireGrace, forKey: Keys.reacquireGrace) }
    }

    /// Drives the inline calibration mode on the Live tab.
    @Published var isEditingZones = false

    private let defaults: UserDefaults

    private enum Keys {
        static let zones = "zones.dropZones.v1"
        static let dwellFrames = "zones.dwellFrames.v1"
        static let reacquireGrace = "zones.reacquireGrace.v1"
    }

    /// `rotation`/`mirror` only shape the first-run layout, so the starting row reads
    /// left-to-right on screen. Calibrated zones are never re-transformed afterwards —
    /// they are pinned to physical bins, not to the preview orientation.
    /// `nil` means "whatever the live preview is currently set to" — resolved in the
    /// body because default argument expressions are evaluated outside the main actor.
    init(
        defaults: UserDefaults = .standard,
        rotation: LivePreviewRotation? = nil,
        mirror: Bool? = nil
    ) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.zones),
           let decoded = try? JSONDecoder().decode([DropZone].self, from: data) {
            zones = decoded
        } else {
            zones = DropZone.defaults(
                rotation: rotation ?? AppSettings.shared.liveRotation,
                mirror: mirror ?? AppSettings.shared.liveMirror
            )
        }

        if defaults.object(forKey: Keys.dwellFrames) != nil {
            dwellFrames = defaults.integer(forKey: Keys.dwellFrames)
        } else {
            dwellFrames = ZoneConfig.defaultDwellFrames
        }

        if defaults.object(forKey: Keys.reacquireGrace) != nil {
            reacquireGrace = defaults.double(forKey: Keys.reacquireGrace)
        } else {
            reacquireGrace = ZoneConfig.defaultReacquireGrace
        }
    }

    func update(_ zones: [DropZone]) {
        guard self.zones != zones else { return }
        self.zones = zones
    }

    func update(_ zone: DropZone) {
        guard let index = zones.firstIndex(where: { $0.id == zone.id }) else { return }
        guard zones[index] != zone else { return }
        zones[index] = zone
    }

    func remove(id: UUID) {
        zones.removeAll { $0.id == id }
    }

    func addZone() {
        let bin = BinGuide.all.first ?? BinGuide.unknown
        zones.append(
            DropZone(
                name: "Zone \(zones.count + 1)",
                binID: bin.id,
                corners: DropZone.rect(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
            )
        )
    }

    func resetToDefaults(
        rotation: LivePreviewRotation? = nil,
        mirror: Bool? = nil
    ) {
        zones = DropZone.defaults(
            rotation: rotation ?? AppSettings.shared.liveRotation,
            mirror: mirror ?? AppSettings.shared.liveMirror
        )
        dwellFrames = ZoneConfig.defaultDwellFrames
        reacquireGrace = ZoneConfig.defaultReacquireGrace
    }

    private func persistZones() {
        guard let data = try? JSONEncoder().encode(zones) else { return }
        defaults.set(data, forKey: Keys.zones)
    }
}
