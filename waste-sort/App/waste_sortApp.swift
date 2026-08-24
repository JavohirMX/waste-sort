//
//  waste_sortApp.swift
//  waste-sort
//
//  Created by Javohir Muhammad on 12/08/26.
//

import SwiftUI
import TipKit

@main
struct WasteSortApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var recording = RecordingController.shared
    @StateObject private var zoneStore = ZoneStore.shared
    @StateObject private var history = ZoneEventHistoryStore.shared
    @StateObject private var aprilTagStore = AprilTagBindingStore.shared
    @StateObject private var binStyle = BinStyleStore.shared
    @StateObject private var verdictLog = FoundationVerdictLog.shared

    @Environment(\.scenePhase) private var scenePhase
    /// Foreground maintenance for the PCC judge store (specs/001): throttled
    /// 30-day prune of crops and records that were never exported.
    private let pccPruneThrottle = PCCJudgeMaintenance()

    init() {
        BrandFont.register()
        try? Tips.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(recording)
                .environmentObject(zoneStore)
                .environmentObject(history)
                .environmentObject(aprilTagStore)
                .environmentObject(binStyle)
                .environmentObject(verdictLog)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        pccPruneThrottle.pruneIfNeeded()
                    }
                }
        }
    }
}

/// Wraps the prune call so it runs at most once per hour, off the frame path.
nonisolated final class PCCJudgeMaintenance: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRun: Date?

    func pruneIfNeeded(now: Date = Date()) {
        lock.lock()
        if let lastRun, now.timeIntervalSince(lastRun) < 3_600 {
            lock.unlock()
            return
        }
        lastRun = now
        lock.unlock()
        Task.detached(priority: .utility) {
            _ = PCCRecordStore().pruneOldRecords()
        }
    }
}
