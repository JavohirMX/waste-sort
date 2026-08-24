import Foundation
import os

/// A correction an operator actually applied, kept with its evidence snapshot
/// so Settings can show why it exists without re-reading judge records.
nonisolated struct AppliedBinOverride: Codable, Equatable, Identifiable, Sendable {
    var id: String { itemClass }
    /// Normalized class key (`BinGuide.normalizedKey`).
    let itemClass: String
    let binID: String
    let appliedAt: Date
    let sampleCount: Int
    let agreementRate: Double
}

/// Lock-guarded persistence for applied bin-routing overrides (specs/002).
/// Read from both worlds — Settings on main and `BinGuide.info(for:)` on the
/// inference queue — hence the NSLock instead of actor hop semantics, mirroring
/// `DetectionLogStore`. Writes happen only from operator actions in Settings.
final class AppliedBinOverrides: @unchecked Sendable {
    /// Process-wide instance wired into `BinGuide` once at app init.
    static let shared = AppliedBinOverrides()

    private let lock = NSLock()
    private var overrides: [String: AppliedBinOverride]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.overrides = Self.load(from: defaults)
    }

    func binID(forClass rawClassName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[BinGuide.normalizedKey(rawClassName)]?.binID
    }

    func all() -> [AppliedBinOverride] {
        lock.lock()
        defer { lock.unlock() }
        return overrides.values.sorted { $0.appliedAt < $1.appliedAt }
    }

    func apply(_ suggestion: SuggestedOverride, appliedAt: Date = Date()) {
        let entry = AppliedBinOverride(
            itemClass: BinGuide.normalizedKey(suggestion.itemClass),
            binID: suggestion.suggestedBinID,
            appliedAt: appliedAt,
            sampleCount: suggestion.sampleCount,
            agreementRate: suggestion.agreementRate
        )
        lock.lock()
        overrides[entry.itemClass] = entry
        persistLocked()
        lock.unlock()
    }

    func remove(itemClassKey rawKey: String) {
        lock.lock()
        overrides[BinGuide.normalizedKey(rawKey)] = nil
        persistLocked()
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        overrides.removeAll()
        persistLocked()
        lock.unlock()
    }

    private static let storageKey = "settings.appliedBinOverrides.v1"

    private static func load(from defaults: UserDefaults) -> [String: AppliedBinOverride] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        do {
            let entries = try PCCRecordCodec.makeDecoder().decode([AppliedBinOverride].self, from: data)
            return Dictionary(
                entries.map { (BinGuide.normalizedKey($0.itemClass), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            // Corrupt store loses overrides, never guidance correctness: the
            // fallback is the static taxonomy. Say so loudly.
            AppLog.persistence.error("Discarding unreadable applied bin overrides: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Caller holds `lock`.
    private func persistLocked() {
        do {
            let data = try PCCRecordCodec.makeEncoder().encode(Array(overrides.values))
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            AppLog.persistence.error("Failed to persist applied bin overrides: \(error.localizedDescription)")
        }
    }
}
