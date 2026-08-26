import Foundation

/// Snapshot of tunable inference and tracking values, passed into Live camera updates.
struct RuntimeSettings: Equatable {
    var confidence: Double
    var iou: Double
    var maxItems: Int
    var decisionPipeline: DecisionPipeline
    var barcodeAssistEnabled: Bool
    var appearanceAssistEnabled: Bool
    var recheckAssistEnabled: Bool
    var verboseDetectionLogging: Bool
    var pccJudgeEnabled: Bool
    var pccConfidentAuditEnabled: Bool
    var confirmHits: Int
    var maxMisses: Int
    var trackerIou: Double
    var crossClassIou: Double
    var beliefThreshold: Double
    var beliefMargin: Double
    var emaAlpha: Double
    var boxInflate: Double
    var maxSpeed: Double
    var preferredCameraID: String
    var selectedModelName: String
    var liveRotation: LivePreviewRotation
    var liveMirror: Bool
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var exposureLocked: Bool
    var focusLocked: Bool
    var whiteBalanceLocked: Bool

    var captureControls: CameraCaptureControls {
        CameraCaptureControls(
            exposureLocked: exposureLocked,
            focusLocked: focusLocked,
            whiteBalanceLocked: whiteBalanceLocked
        )
    }

    var frameColor: FrameColorControls {
        FrameColorControls(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation
        )
    }
}

