//
//  DockMoverApp.swift
//  DockMover
//
//  Created by H on 29/05/2026.
//

import SwiftUI

@main
struct DockMoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DockMoverModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.isEnabled ? "dock.rectangle" : "dock.rectangle")
        }
        .menuBarExtraStyle(.menu)

        Window("DockMover", id: "settings") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 320)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
