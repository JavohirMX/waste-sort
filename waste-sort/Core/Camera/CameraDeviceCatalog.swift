import AVFoundation
import Foundation

/// Preference ID stored in settings. `"auto"` prefers a connected external camera.
enum CameraPreference {
    static let autoID = "auto"
}

enum CameraKind: String, Equatable {
    case builtInBack
    case builtInFront
    case external
}

struct CameraOption: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let kind: CameraKind

    var subtitle: String {
        switch kind {
        case .builtInBack: return "Built-in back"
        case .builtInFront: return "Built-in front"
        case .external: return "USB / external"
        }
    }
}

enum CameraDeviceCatalog {
    /// Lists built-in and UVC external cameras available to the app.
    static func availableOptions() -> [CameraOption] {
        var options: [CameraOption] = []

        if let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            options.append(
                CameraOption(
                    id: back.uniqueID,
                    name: back.localizedName.isEmpty ? "iPad Back Camera" : back.localizedName,
                    kind: .builtInBack
                )
            )
        }

        if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            options.append(
                CameraOption(
                    id: front.uniqueID,
                    name: front.localizedName.isEmpty ? "iPad Front Camera" : front.localizedName,
                    kind: .builtInFront
                )
            )
        }

        let externalSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        for device in externalSession.devices where device.isConnected {
            options.append(
                CameraOption(
                    id: device.uniqueID,
                    name: device.localizedName.isEmpty ? "External Camera" : device.localizedName,
                    kind: .external
                )
            )
        }

        return options
    }

    static func device(forUniqueID id: String) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
                .external
            ],
            mediaType: .video,
            position: .unspecified
        ).devices.first { $0.uniqueID == id && $0.isConnected }
    }

    /// Resolves the capture device for a preference. Auto prefers external when present.
    static func resolveDevice(preferenceID: String) -> AVCaptureDevice? {
        let options = availableOptions()

        if preferenceID != CameraPreference.autoID,
           let match = options.first(where: { $0.id == preferenceID }),
           let device = device(forUniqueID: match.id) {
            return device
        }

        if let external = options.first(where: { $0.kind == .external }),
           let device = device(forUniqueID: external.id) {
            return device
        }

        if let back = options.first(where: { $0.kind == .builtInBack }),
           let device = device(forUniqueID: back.id) {
            return device
        }

        return options.first.flatMap { device(forUniqueID: $0.id) }
    }
}
