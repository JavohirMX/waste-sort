//
//  waste_sortApp.swift
//  waste-sort
//
//  Created by Javohir Muhammad on 12/08/26.
//

import SwiftUI

@main
struct WasteSortApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var recording = RecordingController.shared
    @StateObject private var zoneStore = ZoneStore.shared
    @StateObject private var history = ZoneEventHistoryStore.shared
    @StateObject private var aprilTagStore = AprilTagBindingStore.shared
    @StateObject private var markerStore = BinMarkerStore.shared
    @StateObject private var binStyle = BinStyleStore.shared
    @StateObject private var verdictLog = FoundationVerdictLog.shared
    @StateObject private var binPreview = BinPreviewCoordinator.shared

    init() {
        BrandFont.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(recording)
                .environmentObject(zoneStore)
                .environmentObject(history)
                .environmentObject(aprilTagStore)
                .environmentObject(markerStore)
                .environmentObject(binStyle)
                .environmentObject(verdictLog)
                .environmentObject(binPreview)
                .preferredColorScheme(.light)
        }
    }
}
