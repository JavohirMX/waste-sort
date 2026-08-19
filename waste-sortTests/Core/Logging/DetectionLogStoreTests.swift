import Foundation
import Testing
@testable import waste_sort

@MainActor
struct DetectionLogStoreTests {
    @Test func finishSessionWritesHeaderAndRows() throws {
        let dirs = try ScratchDirectories()
        let store = DetectionLogStore(
            documentsDirectory: dirs.documents,
            supportDirectory: dirs.support
        )
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store.startSession(id: "session-a", startedAt: started, filePrefix: "Sortla-test")
        store.append(event(sessionId: "session-a", startedAt: started, trackId: 1, classKey: "organic"))
        store.append(event(sessionId: "session-a", startedAt: started, trackId: 2, classKey: "residual"))

        let csvURL = try #require(store.finishSession())
        let text = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == DetectionLogEvent.csvHeader)
        #expect(lines.count == 3)
        #expect(lines[1].contains("session-a"))
        #expect(lines[1].contains("organic"))
        #expect(lines[2].contains("residual"))
        #expect(lines[1].contains(",1,"))
        #expect(lines[2].contains(",2,"))
        #expect(!store.isSessionActive)
    }

    @Test func emptySessionWritesHeaderOnlyCSV() throws {
        let dirs = try ScratchDirectories()
        let store = DetectionLogStore(
            documentsDirectory: dirs.documents,
            supportDirectory: dirs.support
        )
        store.startSession(id: "empty", startedAt: Date(), filePrefix: "Sortla-empty")
        let csvURL = try #require(store.finishSession())
        let text = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines == [DetectionLogEvent.csvHeader])
    }

    @Test func leftoverJSONLIsRecoveredToCSV() throws {
        let dirs = try ScratchDirectories()
        let first = DetectionLogStore(
            documentsDirectory: dirs.documents,
            supportDirectory: dirs.support
        )
        let started = Date(timeIntervalSince1970: 1_700_000_100)
        first.startSession(id: "crash-session", startedAt: started, filePrefix: "Sortla-recovered")
        first.append(event(sessionId: "crash-session", startedAt: started, trackId: 7, classKey: "clean_inorganic"))

        let recovered = DetectionLogStore(
            documentsDirectory: dirs.documents,
            supportDirectory: dirs.support
        )
        let urls = recovered.recoverLeftoverSessions()
        #expect(urls.count == 1)
        let text = try String(contentsOf: urls[0], encoding: .utf8)
        #expect(text.contains(DetectionLogEvent.csvHeader))
        #expect(text.contains("crash-session"))
        #expect(text.contains("clean_inorganic"))
        #expect(text.contains(",7,"))
    }
}

private struct ScratchDirectories {
    let documents: URL
    let support: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detection-log-tests-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

private func event(
    sessionId: String,
    startedAt: Date,
    trackId: Int,
    classKey: String
) -> DetectionLogEvent {
    DetectionLogEvent(
        timestamp: startedAt.addingTimeInterval(1.25),
        sessionId: sessionId,
        sessionStartedAt: startedAt,
        trackId: trackId,
        classKey: classKey,
        className: classKey,
        bin: classKey,
        confidence: 0.87,
        model: "bestv3.3",
        confidenceThreshold: 0.6,
        iouThreshold: 0.7,
        cameraId: "auto",
        boxX: 0.1,
        boxY: 0.2,
        boxW: 0.3,
        boxH: 0.4,
        fps: 15
    )
}
