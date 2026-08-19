import Combine
import Foundation

@MainActor
final class AprilTagBindingStore: ObservableObject {
    static let shared = AprilTagBindingStore()

    @Published var bindings: [UUID: Int] { // Zone ID -> Tag ID
        didSet { persist() }
    }
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var showDebugOverlay: Bool {
        didSet { defaults.set(showDebugOverlay, forKey: Keys.debug) }
    }
    @Published var staleTimeout: Double {
        didSet { defaults.set(staleTimeout, forKey: Keys.staleTimeout) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let bindings = "apriltag.bindings"
        static let enabled = "apriltag.enabled"
        static let debug = "apriltag.debug"
        static let staleTimeout = "apriltag.staleTimeout"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.bindings),
           let decoded = try? JSONDecoder().decode([UUID: Int].self, from: data) {
            self.bindings = decoded
        } else {
            self.bindings = [:]
        }
        self.isEnabled = defaults.object(forKey: Keys.enabled) != nil ? defaults.bool(forKey: Keys.enabled) : true
        self.showDebugOverlay = defaults.bool(forKey: Keys.debug)
        if defaults.object(forKey: Keys.staleTimeout) != nil {
            staleTimeout = defaults.double(forKey: Keys.staleTimeout)
        } else {
            staleTimeout = AprilTagConfig.standard.staleTimeout
        }
    }

    func setTagID(_ tagID: Int, for zoneID: UUID) {
        bindings[zoneID] = tagID
    }

    func prune(toActiveZoneIDs activeZoneIDs: Set<UUID>) {
        bindings = bindings.filter { activeZoneIDs.contains($0.key) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: Keys.bindings)
        }
    }
}
