import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: DockMoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(18)

            Divider()

            toolbar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider()

            FakeDockView(model: model)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.isEnabled ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("DockMover")
                    .font(.title2.weight(.semibold))
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if model.isApplying {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("Enabled", isOn: $model.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    model.addAppFromPanel()
                } label: {
                    Label("Choose app...", systemImage: "folder")
                }

                Menu {
                    ForEach(model.runningApps) { app in
                        Button(app.label) {
                            model.addRunningApp(app)
                        }
                    }
                } label: {
                    Label("Running app", systemImage: "bolt.horizontal")
                }
            } label: {
                Label("Add app", systemImage: "plus")
            }

            Menu {
                Button {
                    model.setReserveEmptySlotsForAll(true)
                } label: {
                    Label(
                        "For all apps not running",
                        systemImage: model.draftReservesEmptySlotsForAll ? "checkmark" : "circle"
                    )
                }

                Button {
                    model.setReserveEmptySlotsForAll(false)
                } label: {
                    Label(
                        "Only selected",
                        systemImage: model.draftReservesEmptySlotsForAll ? "circle" : "checkmark"
                    )
                }
            } label: {
                Label("Empty Slots", systemImage: "square.dashed")
            }
            .help("Choose which fake Dock apps reserve empty slots while not running")

            Menu {
                ForEach(DockEmptySlotSize.allCases) { size in
                    Button {
                        model.setEmptySlotSizeForAll(size)
                    } label: {
                        Label(size.label, systemImage: size == .half ? "square.lefthalf.filled" : "square")
                    }
                }
            } label: {
                Label(model.draftEmptySlotSizeForAll.label, systemImage: "arrow.left.and.right")
            }
            .help("Choose the size for global empty slots")

            Menu {
                ForEach(DockRestartMode.allCases) { mode in
                    Button {
                        model.setDockRestartMode(mode)
                    } label: {
                        Label(
                            "\(mode.label) Restart",
                            systemImage: model.dockRestartMode == mode ? "checkmark" : "circle"
                        )
                    }
                    .help(mode == .fast ? "Use a forceful Dock restart that can come back faster but is more abrupt" : "Use the standard Dock restart")
                }
            } label: {
                Label("Refresh Speed", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Choose how aggressively DockMover refreshes the real Dock")

            Spacer()

            Button {
                model.undoLastChange()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)

            Button {
                model.applyNow()
            } label: {
                Label("Apply Saved", systemImage: "checkmark.circle")
            }

            Button {
                model.saveDock()
            } label: {
                Label("Save Dock", systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .disabled(model.isApplying)
    }

}

private struct FakeDockView: View {
    @ObservedObject var model: DockMoverModel
    @State private var showsTargetDockInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Target Dock", systemImage: "dock.rectangle")
                    .font(.title3.weight(.semibold))

                Button {
                    showsTargetDockInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("Target Dock info")
                .popover(isPresented: $showsTargetDockInfo, arrowEdge: .top) {
                    Text("The fake dock is what the dock layout will be if all apps are running at the same time, it will always try to get as close to that target layout as much as possible.")
                        .font(.body)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading)
                        .padding(14)
                }

                Spacer()

                if model.hasUnsavedChanges {
                    Label("Unsaved", systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(model.draftSlots) { slot in
                        FakeDockIcon(
                            slot: slot,
                            isRunning: model.runningState(for: slot),
                            reservesEmptySlot: model.draftReservesEmptySlotsForAll || slot.reservesEmptySlot,
                            emptySlotSize: slot.reservesEmptySlot ? slot.reservedEmptySlotSize : model.draftEmptySlotSizeForAll
                        )
                        .onDrag {
                            NSItemProvider(object: slot.id.uuidString as NSString)
                        }
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            move(providers, before: slot.id)
                        }
                        .contextMenu {
                            Button(slot.isPermanent ? "Show Only While Running" : "Keep in Dock") {
                                model.togglePermanent(slot)
                            }

                            Menu("Reserve Empty Slot") {
                                Button {
                                    model.setReserveEmptySlot(slot, size: .full)
                                } label: {
                                    Label("Full Size", systemImage: "square")
                                }

                                Button {
                                    model.setReserveEmptySlot(slot, size: .half)
                                } label: {
                                    Label("Half Size", systemImage: "square.lefthalf.filled")
                                }

                                if slot.reservesEmptySlot {
                                    Divider()

                                    Button {
                                        model.setReserveEmptySlot(slot, size: nil)
                                    } label: {
                                        Label("Do Not Reserve", systemImage: "xmark")
                                    }
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                model.removeSlot(slot)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }

                    EndDropTarget()
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            moveToEnd(providers)
                        }
                }
                .padding(10)
                .frame(minHeight: 92)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
    }

    private func move(_ providers: [NSItemProvider], before targetID: UUID) -> Bool {
        loadDraggedSlotID(from: providers) { sourceID in
            model.moveDraftSlot(sourceID: sourceID, before: targetID)
        }
    }

    private func moveToEnd(_ providers: [NSItemProvider]) -> Bool {
        loadDraggedSlotID(from: providers) { sourceID in
            model.moveDraftSlotToEnd(sourceID: sourceID)
        }
    }

    private func loadDraggedSlotID(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (UUID) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String ?? (object as? NSString).map(String.init),
                  let sourceID = UUID(uuidString: string) else {
                return
            }

            Task { @MainActor in
                completion(sourceID)
            }
        }

        return true
    }
}

private struct FakeDockIcon: View {
    let slot: DockAppSlot
    let isRunning: Bool
    let reservesEmptySlot: Bool
    let emptySlotSize: DockEmptySlotSize

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                DockIconImage(slot: slot)
                    .frame(width: 54, height: 54)
                    .padding(5)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Circle()
                    .fill(isRunning ? Color.green : Color.clear)
                    .frame(width: 6, height: 6)
                    .offset(y: 5)

                if slot.isPermanent {
                    Image(systemName: "pin.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.blue, in: Circle())
                        .offset(x: 22, y: -41)
                }

                if reservesEmptySlot && !slot.isPermanent && !isRunning {
                    ZStack {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 23, height: 23)

                        if emptySlotSize == .half {
                            Text("1/2")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "square.dashed")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .offset(x: -22, y: -41)
                }
            }
            .frame(width: 66, height: 66)

            Text(slot.label)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 72)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(slot.label)
    }
}

private struct EndDropTarget: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))

            Image(systemName: "arrow.right.to.line.compact")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 54)
        .padding(.bottom, 18)
        .help("Move to end")
    }
}

private struct DockIconImage: View {
    let slot: DockAppSlot

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .scaledToFit()
    }

    private var icon: NSImage {
        if let path = slot.applicationPath, !path.isEmpty {
            return NSWorkspace.shared.icon(forFile: path)
        }

        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

struct MenuBarView: View {
    @ObservedObject var model: DockMoverModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Enabled", isOn: $model.isEnabled)

        Divider()

        Button("Settings") {
            model.showSettingsWindow(openWindow)
        }

        Divider()

        Button("Quit DockMover") {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}
