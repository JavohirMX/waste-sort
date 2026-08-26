import SwiftUI

struct RecordingSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recording: RecordingController

    var body: some View {
        Form {
            Section {
                if recording.canStop {
                    Button("Stop recording", role: .destructive) {
                        recording.stopRecording()
                    }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(recording.isRecording ? Color.red : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(recording.isRecording ? "Recording camera feed…" : "Starting…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.footnote, design: .default))
                } else {
                    Button("Start recording") {
                        recording.startRecording()
                    }
                    .disabled(!recording.canStart)
                }

                Toggle("Auto-record on open", isOn: $settings.autoRecordOnOpen)

                if let status = recording.statusMessage {
                    Text(status)
                        .font(.system(.footnote, design: .default))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Recording")
                    .foregroundStyle(Color.red.opacity(0.85))
            } footer: {
                Text(recordingFooter)
            }
        }
        .font(.system(.body, design: .default))
    }

    private var recordingFooter: String {
        guard recording.hasLiveSession else {
            return "The live camera must be running before you can start a recording."
        }
        let saves = """
            Saves a raw clip to Photos, an overlay clip (boxes, labels, timestamps) to Photos and Files, \
            and a detection CSV to Files (On My iPad/iPhone → Sortla). Records the camera feed only for the raw clip. \
            Saves if you stop, or if the app is backgrounded or closed.
            """
        if settings.autoRecordOnOpen {
            return "Starts automatically when the app opens or returns to the foreground. \(saves)"
        }
        return saves
    }
}
