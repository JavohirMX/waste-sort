import SwiftUI

struct SettingsSidebarGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let panes: [SettingsPane]
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case recording
    case camera
    case zones
    case overlay
    case detection
    case tracking
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .camera: "Camera"
        case .zones: "Zones"
        case .overlay: "Live overlay"
        case .detection: "Detection"
        case .tracking: "Live tracking"
        case .tools: "Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .recording: "record.circle.fill"
        case .camera: "camera.fill"
        case .zones: "square.dashed"
        case .overlay: "rectangle.3.group.fill"
        case .detection: "viewfinder"
        case .tracking: "scope"
        case .tools: "wrench.and.screwdriver.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .recording: .red
        case .camera: .gray
        case .zones: .green
        case .overlay: .purple
        case .detection: .blue
        case .tracking: .orange
        case .tools: .gray
        }
    }

    /// Knob titles on this pane, including the pane name itself so search can jump here.
    var searchTitles: [String] {
        switch self {
        case .recording:
            ["Recording", "Start recording", "Stop recording", "Auto-record on open"]
        case .camera:
            [
                "Camera", "Rotation", "Mirror", "Capture", "Exposure", "Focus", "White balance",
                "Brightness", "Contrast", "Saturation", "Reset capture"
            ]
        case .zones:
            [
                "Zones", "Show zones", "Dwell frames", "Reacquire window", "Throw feedback delay",
                "Edit zones on camera", "Reset zones", "AprilTag", "Enable AprilTag detection",
                "Show debug overlay", "Detection range", "Closed delay", "Tags",
                "Bin openness", "Detected by", "Marker strips", "Printed on the strip",
                "Dashes", "Chevrons", "Bars", "Row height", "Capture resolution"
            ]
        case .overlay:
            [
                "Live overlay", "Style", "Icon", "Category", "Confidence", "Placement",
                "Box label size", "Category size", "Show FPS", "Speak bin on deposit",
                "Scan product barcodes", "Show last deposit on Live", "Throw feedback sounds"
            ]
        case .detection:
            [
                "Detection", "Demo mode", "Model", "Confidence", "Overlap", "Max items",
                "Category confirmation", "Confirm with on-device model", "Status",
                "Show last verdict on Live"
            ]
        case .tracking:
            [
                "Live tracking", "Decision engine", "Confirm frames", "Keep after miss",
                "Same-item overlap", "Class-change overlap", "Verdict certainty", "Verdict margin",
                "Smoothing", "Box padding", "Max jump speed", "Verbose detection log"
            ]
        case .tools:
            [
                "Tools", "History", "Use mock stats data", "Sort a photo",
                "Show onboarding again", "Reset to defaults"
            ]
        }
    }

    static let sidebarGroups: [SettingsSidebarGroup] = [
        SettingsSidebarGroup(id: "session", title: "Session", panes: [.recording]),
        SettingsSidebarGroup(id: "station", title: "Station", panes: [.camera, .zones]),
        SettingsSidebarGroup(
            id: "recognition",
            title: "Recognition",
            panes: [.overlay, .detection, .tracking]
        ),
        SettingsSidebarGroup(id: "developer", title: "Developer", panes: [.tools])
    ]
}
