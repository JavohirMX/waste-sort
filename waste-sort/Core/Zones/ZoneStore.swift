import Combine
import CoreGraphics
import Foundation

enum ZoneConfig {
    static let defaultDwellFrames = 3
    static let dwellRange = 1...15
}

/// Persisted drop zones plus the transient state the live editor needs.
@MainActor
final class ZoneStore: ObservableObject {
    static let shared = ZoneStore()

    @Published private(set) var zones: [DropZone] {
        didSet { persistZones() }
    }

    /// How many consecutive in-zone frames arm a track.
    @Published var dwellFrames: Int {
        didSet { defaults.set(dwellFrames, forKey: Keys.dwellFrames) }
    }

    /// Drives the inline calibration mode on the Live tab.
    @Published var isEditingZones = false

    private let defaults: UserDefaults

    private enum Keys {
        static let zones = "zones.dropZones.v1"
        static let dwellFrames = "zones.dwellFrames.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.zones),
           let decoded = try? JSONDecoder().decode([DropZone].self, from: data)
        {
            zones = decoded
        } else {
            zones = DropZone.defaults()
        }

        if defaults.object(forKey: Keys.dwellFrames) != nil {
            dwellFrames = defaults.integer(forKey: Keys.dwellFrames)
        } else {
            dwellFrames = ZoneConfig.defaultDwellFrames
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

    func resetToDefaults() {
        zones = DropZone.defaults()
        dwellFrames = ZoneConfig.defaultDwellFrames
    }

    private func persistZones() {
        guard let data = try? JSONEncoder().encode(zones) else { return }
        defaults.set(data, forKey: Keys.zones)
    }
}
