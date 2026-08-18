//
//  waste_sortApp.swift
//  waste-sort
//
//  Created by Javohir Muhammad on 12/08/26.
//

import SwiftUI

@main
struct waste_sortApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var recording = RecordingController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(recording)
        }
    }
}
