import Combine
import Foundation

@MainActor
final class AprilTagBindingStore: ObservableObject {
    static let shared = AprilTagBindingStore()

    @Published var bindings: [UUID: [Int]] { // Zone ID -> Tag IDs
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
    /// How far the camera sits from the bins. Drives capture resolution and detector tuning
    /// together, because raising one without the other buys nothing.
    @Published var rangeProfile: AprilTagRangeProfile {
        didSet { defaults.set(rangeProfile.rawValue, forKey: Keys.rangeProfile) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let bindings = "apriltag.bindings"
        static let enabled = "apriltag.enabled"
        static let debug = "apriltag.debug"
        static let staleTimeout = "apriltag.staleTimeout"
        static let rangeProfile = "apriltag.rangeProfile"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.bindings) {
            if let decoded = try? JSONDecoder().decode([UUID: [Int]].self, from: data) {
                self.bindings = decoded
            } else if let legacy = try? JSONDecoder().decode([UUID: Int].self, from: data) {
                // Migrate single-tag bindings [UUID: Int] -> [UUID: [Int]]
                self.bindings = legacy.mapValues { [$0] }
            } else {
                self.bindings = [:]
            }
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
        self.rangeProfile = defaults.string(forKey: Keys.rangeProfile)
            .flatMap(AprilTagRangeProfile.init(rawValue:)) ?? .far
    }

    func tagIDs(for zoneID: UUID, defaultIndex: Int) -> [Int] {
        bindings[zoneID] ?? AprilTagConfig.defaultTagIDs(forIndex: defaultIndex)
    }

    func setTagIDs(_ tagIDs: [Int], for zoneID: UUID) {
        bindings[zoneID] = tagIDs
    }

    func setTagID(_ tagID: Int, for zoneID: UUID) {
        bindings[zoneID] = [tagID]
    }

    func setTagPreset(groupIndex: Int, for zoneID: UUID) {
        bindings[zoneID] = AprilTagConfig.defaultTagIDs(forIndex: groupIndex)
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
