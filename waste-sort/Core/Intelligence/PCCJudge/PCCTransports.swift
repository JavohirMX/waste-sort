import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Sentinel label for text-only PCC probes. Kept outside the iOS-27 gate so
/// diagnostic surfaces (which run on any OS) can reference it.
nonisolated enum PCCTextProbe {
    static let label = "text_probe"
}

/// Kill switch for PCC image-attachment attempts. Lives outside the iOS-27
/// gate so diagnostic surfaces (which run on any OS) can read and flip it.
///
/// History: the iOS 27 betas ≤4 (with a mismatched Xcode 27 beta-1 SDK)
/// trapped (EXC_BAD_ACCESS) inside the framework on any image attachment, so
/// this was default-OFF. Beta 6 with a matched toolchain verified image calls
/// end-to-end on device and simulator, so the default is now ON. The gate
/// stays as a one-toggle kill switch: if a future beta reintroduces the trap
/// (which cannot be caught in-process), flip it OFF here and the app records
/// honest `skippedUnavailable` records instead of crashing. The text probe
/// and all live-path gating (quota, breaker, records) are unaffected.
nonisolated enum PCCVisionGate {
    static let defaultsKey = "settings.pccVisionAttemptsEnabled"

    nonisolated(unsafe) static var enabled =
        (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true

    static func setEnabled(_ newValue: Bool) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: defaultsKey)
    }
}

/// Strict parser for the model's one-line output contract. Pure string logic,
/// deliberately OUTSIDE the iOS-27 gate so it is unit-testable on every
/// simulator and reusable by any transport.
///
/// The bin comes ONLY from the `bin=` field: whole-line matching let a
/// rationale such as "not clean_inorganic because dirty" flip the parsed
/// label, and bad labels poison both the corrections analyzer and the
/// fine-tuning dataset. No `bin=` field or an unknown token = failure, never
/// a guess (Constitution III).
nonisolated enum PCCVerdictParser {
    private static let candidates = ["dirty_recyclable", "clean_inorganic", "residual", "organic"]

    static func parse(_ text: String) -> (bin: String, material: String?, rationale: String?)? {
        let lowered = text.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let binRange = lowered.range(
            of: "(?<![a-z])bin\\s*=\\s*([a-z_]+)",
            options: .regularExpression
        ) else { return nil }
        let binToken = lowered[binRange]
            .replacingOccurrences(of: "bin", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        guard candidates.contains(binToken) else { return nil }
        // Material/rationale keep their ORIGINAL casing: match case-insensitively
        // on the untouched text so dataset metadata is not degraded to lowercase.
        return (binToken, materialValue(in: text, key: "material"), materialValue(in: text, key: "rationale"))
    }

    private static func materialValue(in text: String, key: String) -> String? {
        guard let range = text.range(of: "(?i)\(key)\\s*=\\s*([^;\\n]+)", options: .regularExpression) else {
            return nil
        }
        let value = text[range].replacingOccurrences(of: "\(key)", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        return value.isEmpty ? nil : value
    }
}

#if canImport(FoundationModels)
import UIKit

/// Builds the real FoundationModels transport. Isolated here so the rest of
/// the service stays unit-testable without touching iOS-27-only symbols.
///
/// Call-pattern notes from on-device bring-up (iPhone, iOS 27 betas):
/// `respond(generating:)` — guided generation — combined with a raw `CGImage`
/// trapped inside the framework on early betas, so the transport uses the
/// most conservative proven pattern instead: a plain-text `respond`, a strict
/// one-line output contract parsed in-app (unparseable output is an honest
/// error, never a guess), and the image normalized to an 8-bit sRGB JPEG
/// file handed over via `Attachment(imageURL:)` — the shape verified
/// end-to-end on beta 6 (device + simulator, ~1–2 s verdicts).
@available(iOS 27.0, *)
nonisolated enum PCCTransportFactory {
    private static let instructions = """
        You are a waste-sorting judge for a kiosk in Bali, Indonesia under
        Provincial Regulation Pergub 47/2019 and 97/2018. Examine the item image
        carefully. Decide which single stream it belongs in: organic, residual,
        clean_inorganic (clean recyclables such as dry plastic, metal, glass,
        paper), or dirty_recyclable (recyclable items possibly contaminated by
        food, drink, sauce, or oil — rinse then recycle, otherwise residual).
        When unsure even after careful examination, choose residual.
        Reply with EXACTLY one line and nothing else, in this format:
        bin=<organic|residual|clean_inorganic|dirty_recyclable>; material=<primary material, short>; rationale=<one short sentence>
        """

    /// Sentinel `yoloLabel` that makes the transport send a text-only probe
    /// (no attachment). The one non-crashing way to prove PCC connectivity,
    /// quota, and entitlement channel while the vision path is under diagnosis.
    static let textProbeLabel = PCCTextProbe.label

    /// Vision preflight, two layers, kept out of the transport closure for
    /// size: the kill switch first (a beta regression must degrade to honest
    /// records, never a trap), then the SDK capability flags for runtimes
    /// that honestly lack vision. Returns the failure answer to record, or
    /// nil when image content may proceed.
    private static func visionGateFailure(
        isTextProbe: Bool,
        model: PrivateCloudComputeLanguageModel
    ) -> ArbiterError? {
        if isTextProbe { return nil }
        if !PCCVisionGate.enabled {
            return .unavailable(
                "image attachments are disabled: this iOS beta traps on PCC vision calls "
                    + "(text path verified working). Re-enable image judgments after a beta update to test again."
            )
        }
        if !model.capabilities.contains(.vision) {
            return .unavailable(
                "this PCC runtime does not declare vision support (capabilities: \(describe(model.capabilities)))"
            )
        }
        return nil
    }

    /// Normalizes the crop for a prompt (8-bit sRGB JPEG temp file) or nil
    /// for the text-only probe. Shared by both transports so the only
    /// variable between them is the model being asked.
    private static func preparedImageURL(
        isTextProbe: Bool,
        crop: CGImage?
    ) -> Result<URL?, ArbiterError> {
        guard !isTextProbe else { return .success(nil) }
        guard let crop else { return .failure(.failed("no crop available")) }
        do {
            return .success(try normalizedJPEGURL(crop))
        } catch {
            return .failure(.failed("image normalization failed: \(error.localizedDescription)"))
        }
    }

    /// Sends the shared verdict prompt — text-only for the probe sentinel,
    /// otherwise instructions + label hint + image attachment — and parses
    /// the strict one-line contract. Unparseable output is an honest error,
    /// never a guess.
    private static func sendAndParse(
        session: LanguageModelSession,
        isTextProbe: Bool,
        imageURL: URL?,
        labelHint: String,
        probeSummary: String
    ) async throws -> Result<ArbiterAnswer, ArbiterError> {
        let started = CFAbsoluteTimeGetCurrent()
        let response = try await session.respond {
            if isTextProbe {
                "Connectivity probe. Reply with exactly: OK"
            } else {
                """
                \(instructions)
                Judge the item in the attached image. On-device label hint: \(labelHint) (may be unavailable).
                """
                if let imageURL {
                    Attachment(imageURL: imageURL).label("cropped item")
                }
            }
        }
        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let text = response.content
        if isTextProbe {
            return .success(ArbiterAnswer(
                rawBinLabel: text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64).description,
                material: "connectivity probe",
                reasoningSummary: probeSummary,
                latencyMs: latencyMs
            ))
        }
        guard let parsed = parseVerdict(text) else {
            return .failure(.failed("unparseable model response: \(String(text.prefix(160)))"))
        }
        return .success(ArbiterAnswer(
            rawBinLabel: parsed.bin,
            material: parsed.material,
            reasoningSummary: parsed.rationale,
            latencyMs: latencyMs,
            inputTokens: response.usage.input.totalTokenCount,
            outputTokens: response.usage.output.totalTokenCount
        ))
    }

    /// The production PCC transport. Session + respond form mirrored from the
    /// validated text-based PCC app on this device: `LanguageModelSession(
    /// model:)` with no instructions parameter. The prompt builder is
    /// required to carry an Attachment; the text probe uses the same builder
    /// WITHOUT one, so on-device results bisect cleanly.
    static func defaultTransport() -> ArbitrationTransport {
        { query, crop in
            let isTextProbe = query.yoloLabel == textProbeLabel
            let imageURL: URL?
            switch preparedImageURL(isTextProbe: isTextProbe, crop: crop) {
            case .failure(let error): return .failure(error)
            case .success(let url): imageURL = url
            }
            defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
            do {
                let model = PrivateCloudComputeLanguageModel()
                if let gateFailure = visionGateFailure(isTextProbe: isTextProbe, model: model) {
                    return .failure(gateFailure)
                }
                let session = LanguageModelSession(model: model)
                return try await sendAndParse(
                    session: session,
                    isTextProbe: isTextProbe,
                    imageURL: imageURL,
                    labelHint: query.yoloLabel,
                    probeSummary: "text-only PCC probe succeeded"
                )
            } catch let error as PrivateCloudComputeLanguageModel.Error {
                switch error {
                case .quotaLimitReached:
                    let reset = PrivateCloudComputeLanguageModel().quotaUsage.resetDate
                    return .failure(.quotaLimitReached(reset: reset))
                @unknown default:
                    return .failure(.failed(String(describing: error)))
                }
            } catch {
                // The concrete case (e.g. unsupportedContent vs
                // guardrailViolation) is the diagnostic payload; the
                // localized description alone hides it.
                return .failure(.failed("\(String(describing: error)) — \(error.localizedDescription)"))
            }
        }
    }

    /// Same prompt/attachment shape as `defaultTransport` but against the
    /// on-device model. Diagnostic bisection: if the on-device model answers
    /// about the same image the PCC path rejects, the shared prompt and
    /// attachment code are exonerated — the difference is the model pipeline
    /// itself. No quota handling; the on-device model has none.
    static func onDeviceTransport() -> ArbitrationTransport {
        { query, crop in
            let isTextProbe = query.yoloLabel == textProbeLabel
            let imageURL: URL?
            switch preparedImageURL(isTextProbe: isTextProbe, crop: crop) {
            case .failure(let error): return .failure(error)
            case .success(let url): imageURL = url
            }
            defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
            do {
                let model = SystemLanguageModel.default
                guard case .available = model.availability else {
                    return .failure(.unavailable(
                        "on-device model unavailable: \(String(describing: model.availability))"
                    ))
                }
                let session = LanguageModelSession(model: model)
                return try await sendAndParse(
                    session: session,
                    isTextProbe: isTextProbe,
                    imageURL: imageURL,
                    labelHint: query.yoloLabel,
                    probeSummary: "text-only on-device probe succeeded"
                )
            } catch {
                return .failure(.failed("\(String(describing: error)) — \(error.localizedDescription)"))
            }
        }
    }

    /// Human-readable capability set for diagnostics surfaces.
    static func capabilitiesSummary() -> String? {
        guard #available(iOS 27.0, *) else { return nil }
        let capabilities = PrivateCloudComputeLanguageModel().capabilities
        return describe(capabilities)
    }

    private static func describe(_ capabilities: LanguageModelCapabilities) -> String {
        let all: [(LanguageModelCapabilities.Capability, String)] = [
            (.vision, "vision"),
            (.guidedGeneration, "guidedGeneration"),
            (.reasoning, "reasoning"),
            (.toolCalling, "toolCalling")
        ]
        let supported = all.filter { capabilities.contains($0.0) }.map(\.1)
        return supported.isEmpty ? "none" : supported.joined(separator: ", ")
    }

    /// Redraws any bitmap into a plain 8-bit sRGB JPEG on disk. Gallery-derived
    /// CGImages can be 10-bit, Display-P3, or float; the framework's attachment
    /// path is at its most proven with exactly what the validated benchmark fed it.
    private static func normalizedJPEGURL(_ image: CGImage) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PCCImageNormalizationError.contextFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else {
            throw PCCImageNormalizationError.makeImageFailed
        }
        guard let jpeg = UIImage(cgImage: normalized).jpegData(compressionQuality: 0.85) else {
            throw PCCImageNormalizationError.jpegFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcc-judge-\(UUID().uuidString).jpg")
        try jpeg.write(to: url, options: .atomic)
        return url
    }

    /// Strict parser for the one-line output contract. See `PCCVerdictParser`
    /// (ungated) for the field-scoped matching rules.
    static func parseVerdict(_ text: String) -> (bin: String, material: String?, rationale: String?)? {
        PCCVerdictParser.parse(text)
    }
}

/// Why image normalization could not produce the JPEG the transport needs.
private enum PCCImageNormalizationError: Error {
    case contextFailed
    case makeImageFailed
    case jpegFailed
}
#endif
