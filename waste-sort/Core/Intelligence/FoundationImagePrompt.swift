import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)

/// The one place that hands an image to a Foundation model.
///
/// Which API can carry an image depends on the OS *build* rather than its version, so the
/// route is chosen at runtime from `FoundationModelsABI`. Each route lives in its own
/// `@inline(never)` function: type metadata and protocol conformances are weak imports too,
/// not just the calls, and inlining could materialise the unavailable one's metadata on a
/// path that was supposed to be dead.
@available(iOS 27.0, *)
nonisolated enum FoundationImagePrompt {
    static func respond<Content: Generable>(
        instructions: String,
        ask: String,
        imageLabel: String,
        image: CGImage,
        generating: Content.Type,
        maximumResponseTokens: Int
    ) async throws -> Content {
        if FoundationModelsABI.supportsAttachmentImagePrompt {
            return try await respondViaAttachment(
                instructions: instructions,
                ask: ask,
                imageLabel: imageLabel,
                image: image,
                generating: generating,
                maximumResponseTokens: maximumResponseTokens
            )
        }
        return try await respondViaTranscript(
            instructions: instructions,
            ask: ask,
            imageLabel: imageLabel,
            image: image,
            generating: generating,
            maximumResponseTokens: maximumResponseTokens
        )
    }

    // MARK: - Route 1: prompt attachment (current API)

    @inline(never)
    private static func respondViaAttachment<Content: Generable>(
        instructions: String,
        ask: String,
        imageLabel: String,
        image: CGImage,
        generating: Content.Type,
        maximumResponseTokens: Int
    ) async throws -> Content {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )
        return try await session.respond(
            generating: generating,
            options: GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: maximumResponseTokens
            )
        ) {
            ask
            Attachment(image).label(imageLabel)
        }.content
    }

    // MARK: - Route 2: transcript attachment (older iOS 27 builds)
    //
    // The image has to ride in a `.prompt` entry. Seeded into `.instructions` it is silently
    // dropped, and the model answers from the text alone — which under greedy sampling means
    // the same fabricated answer for every frame.

    @inline(never)
    private static func respondViaTranscript<Content: Generable>(
        instructions: String,
        ask: String,
        imageLabel: String,
        image: CGImage,
        generating: Content.Type,
        maximumResponseTokens: Int
    ) async throws -> Content {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            transcript: imageTranscript(instructions: instructions, ask: ask, imageLabel: imageLabel, image: image)
        )
        return try await session.respond(
            generating: generating,
            options: GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: maximumResponseTokens
            )
        ) {
            continuationAsk
        }.content
    }

    private static let continuationAsk = "Answer the question above using the attached image."

    private static func imageTranscript(
        instructions: String,
        ask: String,
        imageLabel: String,
        image: CGImage
    ) -> Transcript {
        Transcript(entries: [
            .instructions(
                Transcript.Instructions(
                    id: UUID().uuidString,
                    segments: [
                        .text(Transcript.TextSegment(id: UUID().uuidString, content: instructions)),
                    ],
                    toolDefinitions: []
                )
            ),
            .prompt(
                Transcript.Prompt(
                    id: UUID().uuidString,
                    segments: [
                        .attachment(
                            Transcript.AttachmentSegment(
                                id: UUID().uuidString,
                                content: .image(Transcript.ImageAttachment(image)),
                                label: imageLabel
                            )
                        ),
                        .text(Transcript.TextSegment(id: UUID().uuidString, content: ask)),
                    ],
                    options: GenerationOptions(),
                    responseFormat: nil
                )
            ),
        ])
    }
}

#endif
