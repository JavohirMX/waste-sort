import Darwin
import Foundation

/// Runtime presence checks for the FoundationModels symbols this app calls that are newer
/// than its deployment target.
///
/// The framework itself has shipped since iOS 26 and is linked normally. The image-prompt
/// API is iOS 27, though, and the app deploys to 26.5 — so the compiler emits those symbols
/// as **weak imports**. A weak import the running OS does not export binds to address 0, and
/// the call site branches straight there: the kernel kills the process with
/// `EXC_BAD_ACCESS` / `KERN_PROTECTION_FAILURE at 0x0`. There is no Swift error to catch and
/// no `do/catch` that helps, and `#available(iOS 27, *)` does not save you — the hazard is a
/// *build* mismatch, an iOS 27 device whose FoundationModels predates the SDK the app was
/// compiled against. That happens routinely on beta OSes.
///
/// To regenerate the lists below after an SDK change, build the app and read the weak
/// imports straight out of the object files:
///
///     nm -m <DerivedData>/…/Objects-normal/arm64/*.o \
///       | grep 'weak external' | grep FoundationModels
///
/// `dlsym` wants the name without the leading underscore `nm` prints.
nonisolated enum FoundationModelsABI {
    /// True when a structured prompt can carry an image at all, by either route below.
    static var supportsStructuredImagePrompt: Bool {
        supportsStructuredPrompt && (supportsAttachmentImagePrompt || supportsTranscriptImagePrompt)
    }

    /// Guided generation and the options type, independent of how the image gets attached.
    static let supportsStructuredPrompt: Bool = allLinked(structuredPromptSymbols)

    /// The current API — `Attachment<ImageAttachmentContent>` built into the prompt.
    static let supportsAttachmentImagePrompt: Bool = allLinked(attachmentImagePromptSymbols)

    /// The fallback — `Transcript.ImageAttachment` seeded into the session transcript.
    /// Present on older iOS 27 builds, so the model stays usable there.
    static let supportsTranscriptImagePrompt: Bool = allLinked(transcriptImagePromptSymbols)

    /// Operator-facing summary of which route is in use, for the settings sheet.
    static var imageRouteDetail: String {
        if !supportsStructuredPrompt {
            return "Guided generation is missing from this iOS build."
        }
        if supportsAttachmentImagePrompt { return "Prompt attachment." }
        if supportsTranscriptImagePrompt { return "Transcript attachment (older iOS 27 build)." }
        return "This iOS build exports neither image-prompt API. Update iOS to match the Xcode SDK."
    }

    // MARK: - Symbol inventory

    /// `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`, the iOS 27
    /// additions to `Generable`, and the parsing error the `@Generable` expansion throws.
    private static let structuredPromptSymbols = [
        "$s16FoundationModels17GenerationOptionsV12samplingMode11temperature21maximumResponseTokensA2C08SamplingF0VSg_SdSgSiSgtcfC",
        "$s16FoundationModels9GenerablePAAE20promptRepresentationAA6PromptVvg",
        "$s16FoundationModels9GenerablePAAE26instructionsRepresentationAA12InstructionsVvg",
        "$s16FoundationModels16GeneratedContentV12ParsingErrorVMa",
        "$s16FoundationModels16GeneratedContentV12ParsingErrorVs0F0AAMc",
        "$s16FoundationModels16GeneratedContentV12ParsingErrorV03rawD0010underlyingF016debugDescriptionAESS_s0F0_pSgSStcfC",
    ]

    /// `Attachment<ImageAttachmentContent>(_ cgImage:orientation:)`, `.label(_:)`, and the
    /// `PromptRepresentable` conformance the prompt builder needs.
    private static let attachmentImagePromptSymbols = [
        "$s16FoundationModels10AttachmentVMn",
        "$s16FoundationModels22ImageAttachmentContentVMn",
        "$s16FoundationModels10AttachmentV5labelyACyxGSSF",
        "$s16FoundationModels10AttachmentVA2A05ImageC7ContentVRszlE_11orientationACyAEGSo10CGImageRefa_So0G19PropertyOrientationVSgtcfC",
        "$s16FoundationModels10AttachmentVyxGAA19PromptRepresentableAAMc",
    ]

    /// `Transcript.ImageAttachment` / `AttachmentSegment` and the enum cases that carry them.
    private static let transcriptImagePromptSymbols = [
        "$s16FoundationModels10TranscriptV10AttachmentOMa",
        "$s16FoundationModels10TranscriptV15ImageAttachmentV_11orientationAESo10CGImageRefa_So0G19PropertyOrientationVSgtcfC",
        "$s16FoundationModels10TranscriptV10AttachmentO5imageyAeC05ImageD0VcAEmFWC",
        "$s16FoundationModels10TranscriptV17AttachmentSegmentV2id7content5labelAESS_AC0D0OSSSgtcfC",
        "$s16FoundationModels10TranscriptV7SegmentO10attachmentyAeC010AttachmentD0VcAEmFWC",
    ]

    // MARK: - Probe

    private static func allLinked(_ mangledNames: [String]) -> Bool {
        mangledNames.allSatisfy(isLinked)
    }

    /// `dlsym` against `RTLD_DEFAULT`, which searches every globally loaded image.
    private static func isLinked(_ mangledName: String) -> Bool {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        return dlsym(rtldDefault, mangledName) != nil
    }
}
