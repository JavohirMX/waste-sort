import Foundation

/// One arbitration attempt, persisted forever (or until pruned) as a JSONL
/// line. This is the teaching-dataset atom: everything a future training run
/// needs to compare what the kiosk did against what the stronger model said,
/// without ever touching the app again.
///
/// Schema version 1 — bump and add fields only; never repurpose existing ones
/// (spec FR-9). Dates serialize as ISO-8601 so exports parse anywhere.
nonisolated struct PCCVerdictRecord: Equatable, Sendable, Codable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var timestamp: Date
    var sessionId: String?
    var trackId: Int
    /// `crops/<uuid>.jpg`, relative to the store root. Nil when crop extraction
    /// failed or was impossible.
    var cropFile: String?
    var yoloLabel: String
    var yoloConfidence: Double
    var beliefUncertain: Bool
    var beliefMargin: Double
    var engineBinID: String
    var pipeline: String
    var outcome: Outcome
    var pccBinID: String?
    var pccRawBinLabel: String?
    var mappingFailed: Bool
    var material: String?
    var reasoningSummary: String?
    var agreesWithEngine: Bool?
    var latencyMs: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var quotaStateAtCall: String?
    var modelId: String
    var reasoningLevel: String
    var errorMessage: String?

    /// Diagnostic pipelines (the photo smoke screen) prove connectivity and
    /// land in exports as evidence, but they carry no routing signal: there is
    /// no model verdict to correct. The policy analyzer skips them.
    var isDiagnostic: Bool { pipeline.lowercased().contains("smoke") }

    nonisolated enum Outcome: Equatable, Sendable, Codable {
        case answered
        case timeout
        case error(String)
        case skippedQuota
        case skippedUnavailable(String)
        case skippedOffline
        case skippedDisabled
        case cropFailed

        private enum CodingKeys: String, CodingKey {
            case tag = "outcome", message
        }

        private enum Tag: String, Codable {
            case answered, timeout, error
            case skippedQuota
            case skippedUnavailable
            case skippedOffline
            case skippedDisabled
            case cropFailed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(Tag.self, forKey: .tag)
            switch tag {
            case .answered: self = .answered
            case .timeout: self = .timeout
            case .error:
                self = .error(try container.decodeIfPresent(String.self, forKey: .message) ?? "unknown")
            case .skippedQuota: self = .skippedQuota
            case .skippedUnavailable:
                self = .skippedUnavailable(
                    try container.decodeIfPresent(String.self, forKey: .message) ?? "unknown"
                )
            case .skippedOffline: self = .skippedOffline
            case .skippedDisabled: self = .skippedDisabled
            case .cropFailed: self = .cropFailed
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .answered:
                try container.encode(Tag.answered, forKey: .tag)
            case .timeout:
                try container.encode(Tag.timeout, forKey: .tag)
            case .error(let message):
                try container.encode(Tag.error, forKey: .tag)
                try container.encode(message, forKey: .message)
            case .skippedQuota:
                try container.encode(Tag.skippedQuota, forKey: .tag)
            case .skippedUnavailable(let reason):
                try container.encode(Tag.skippedUnavailable, forKey: .tag)
                try container.encode(reason, forKey: .message)
            case .skippedOffline:
                try container.encode(Tag.skippedOffline, forKey: .tag)
            case .skippedDisabled:
                try container.encode(Tag.skippedDisabled, forKey: .tag)
            case .cropFailed:
                try container.encode(Tag.cropFailed, forKey: .tag)
            }
        }
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionId: String? = nil,
        trackId: Int,
        cropFile: String?,
        yoloLabel: String,
        yoloConfidence: Double,
        beliefUncertain: Bool,
        beliefMargin: Double,
        engineBinID: String,
        pipeline: String,
        outcome: Outcome,
        pccBinID: String? = nil,
        pccRawBinLabel: String? = nil,
        mappingFailed: Bool = false,
        material: String? = nil,
        reasoningSummary: String? = nil,
        agreesWithEngine: Bool? = nil,
        latencyMs: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        quotaStateAtCall: String? = nil,
        modelId: String = "pcc",
        reasoningLevel: String = WasteSortConfig.defaultPCCReasoningLevel
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.trackId = trackId
        self.cropFile = cropFile
        self.yoloLabel = yoloLabel
        self.yoloConfidence = yoloConfidence
        self.beliefUncertain = beliefUncertain
        self.beliefMargin = beliefMargin
        self.engineBinID = engineBinID
        self.pipeline = pipeline
        self.outcome = outcome
        self.pccBinID = pccBinID
        self.pccRawBinLabel = pccRawBinLabel
        self.mappingFailed = mappingFailed
        self.material = material
        self.reasoningSummary = reasoningSummary
        self.agreesWithEngine = agreesWithEngine
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.quotaStateAtCall = quotaStateAtCall
        self.modelId = modelId
        self.reasoningLevel = reasoningLevel
        self.errorMessage = nil
    }

    /// Builds the answered-record tail from an `ArbiterAnswer`, mapping the
    /// model's label into the project taxonomy. An unmappable label is data,
    /// not a crash: it lands in `pccRawBinLabel` with `mappingFailed` set.
    static func answered(
        from context: ArbiterRequestContext,
        answer: ArbiterAnswer,
        cropFile: String?,
        quotaState: String?
    ) -> PCCVerdictRecord {
        let mapped = BinGuide.info(for: answer.rawBinLabel)
        let known = BinGuide.bin(id: mapped.id)
        let isKnownBin = mapped.id != BinGuide.unknown.id || answer.rawBinLabel.lowercased() == BinGuide.unknown.id
        return PCCVerdictRecord(
            sessionId: context.sessionId,
            trackId: context.trackId,
            cropFile: cropFile,
            yoloLabel: context.yoloLabel,
            yoloConfidence: context.yoloConfidence,
            beliefUncertain: context.beliefUncertain,
            beliefMargin: context.beliefMargin,
            engineBinID: context.engineBinID,
            pipeline: context.pipeline,
            outcome: .answered,
            pccBinID: isKnownBin ? mapped.id : nil,
            pccRawBinLabel: answer.rawBinLabel,
            mappingFailed: !isKnownBin,
            material: answer.material,
            reasoningSummary: answer.reasoningSummary,
            agreesWithEngine: isKnownBin ? mapped.id == context.engineBinID : nil,
            latencyMs: answer.latencyMs,
            inputTokens: answer.inputTokens,
            outputTokens: answer.outputTokens,
            quotaStateAtCall: quotaState
        )
    }
}

/// Shared JSONL encoding rules for records and export manifests.
nonisolated enum PCCRecordCodec {
    static func encodeLine(_ record: PCCVerdictRecord, encoder: JSONEncoder) throws -> Data {
        try encoder.encode(record)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
