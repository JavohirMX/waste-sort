import Combine
import CoreGraphics
import Foundation

/// One trip to the on-device model, recorded whether or not it produced a lock.
///
/// This exists to answer "why is nothing being confirmed?" on a live station, which is a
/// question the boxes alone cannot answer: a declined answer and a model that never
/// responded look identical on screen.
nonisolated struct FoundationVerdictRecord: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Accepted, and now locked to the item.
        case locked(binID: String)
        /// The model answered but would not commit.
        case declined(reason: String)
        /// The call threw.
        case failed(String)
    }

    let id: UUID
    let timestamp: Date
    let trackID: Int
    /// What the model called the item, in its own words. Empty when the call failed.
    let label: String
    let confidence: Double
    /// What the detector called the same item at the moment the crop was sent — the whole
    /// point of running both.
    let detectorClassKey: String
    /// Seconds the model took. The one number that decides whether this is usable live.
    let latency: TimeInterval
    let outcome: Outcome
    /// A small copy of the exact crop the model was shown. Without it the log tells you the
    /// answer but not the question, and most surprising answers turn out to be a bad crop.
    /// Downscaled hard, because forty full-size crops would cost tens of megabytes.
    let thumbnail: CGImage?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        trackID: Int,
        label: String,
        confidence: Double,
        detectorClassKey: String,
        latency: TimeInterval,
        outcome: Outcome,
        thumbnail: CGImage? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.trackID = trackID
        self.label = label
        self.confidence = confidence
        self.detectorClassKey = detectorClassKey
        self.latency = latency
        self.outcome = outcome
        self.thumbnail = thumbnail
    }

    /// Identity is the id. `CGImage` is not `Equatable`, and two records never share one
    /// anyway — each is a separate trip to the model.
    static func == (lhs: FoundationVerdictRecord, rhs: FoundationVerdictRecord) -> Bool {
        lhs.id == rhs.id
    }

    /// The bin that was locked, if one was.
    var lockedBinID: String? {
        if case .locked(let binID) = outcome { return binID }
        return nil
    }

    /// True when the model and the detector disagreed — the interesting rows.
    var disagreesWithDetector: Bool {
        guard let lockedBinID else { return false }
        return BinGuide.info(for: detectorClassKey).id != lockedBinID
    }
}

/// In-memory ring of recent model verdicts, for the debug strip on Live.
///
/// Deliberately not persisted: this is a window onto what the model is doing right now, not
/// a record of what was thrown away. The deposit history already keeps the latter, and
/// keeping two durable logs that disagree would be worse than keeping one.
@MainActor
final class FoundationVerdictLog: ObservableObject {
    static let shared = FoundationVerdictLog()

    /// Newest first.
    @Published private(set) var records: [FoundationVerdictRecord] = []

    /// Enough to see a pattern, few enough to stay free.
    private let capacity: Int

    init(capacity: Int = 40) {
        self.capacity = capacity
    }

    func append(_ incoming: [FoundationVerdictRecord]) {
        guard !incoming.isEmpty else { return }
        records.insert(contentsOf: incoming.reversed(), at: 0)
        if records.count > capacity {
            records.removeSubrange(capacity...)
        }
    }

    func clear() {
        guard !records.isEmpty else { return }
        records.removeAll()
    }
}
