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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
