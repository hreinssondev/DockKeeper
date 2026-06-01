//
//  DockMoverApp.swift
//  DockMover
//
//  Created by H on 29/05/2026.
//

import AppKit
import SwiftUI

@main
struct DockMoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DockMoverModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("DockMover", id: "settings") {
            ContentView(model: model)
                .frame(
                    minWidth: 720,
                    idealWidth: 900,
                    maxWidth: .infinity,
                    minHeight: 320,
                    idealHeight: 320,
                    maxHeight: .infinity
                )
                .background(SettingsWindowProbe { window in
                    model.configureSettingsWindow(window)
                })
        }
        .defaultSize(width: 900, height: 320)
        .defaultPosition(.center)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: DockMoverModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.isEnabled ? "dock.rectangle" : "dock.rectangle")
            .onAppear {
                model.setSettingsWindowOpener {
                    openWindow(id: "settings")
                }
            }
    }
}

private struct SettingsWindowProbe: NSViewRepresentable {
    let onWindowChange: (NSWindow) -> Void

    func makeNSView(context: Context) -> SettingsWindowProbeView {
        let view = SettingsWindowProbeView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: SettingsWindowProbeView, context: Context) {
        view.onWindowChange = onWindowChange
        if let window = view.window {
            onWindowChange(window)
        }
    }
}

private final class SettingsWindowProbeView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window {
            onWindowChange?(window)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }
}
