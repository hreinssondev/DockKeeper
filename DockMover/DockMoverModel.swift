import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DockMoverModel: ObservableObject {
    private enum SettingsWindowDefaultFrame {
        static let minContentSize = CGSize(width: 720, height: 320)
        static let contentHeight: CGFloat = 320
    }

    @Published var isEnabled: Bool {
        didSet {
            persist()
            if isEnabled {
                scheduleApply(reason: "Enabled DockMover")
            }
        }
    }

    @Published private(set) var savedSlots: [DockAppSlot] = []
    @Published private(set) var draftSlots: [DockAppSlot] = []
    @Published private(set) var runningApps: [RunningDockApp] = []
    @Published private(set) var status: String = "Ready"
    @Published private(set) var isApplying = false
    @Published private(set) var savedReservesEmptySlotsForAll = false
    @Published private(set) var draftReservesEmptySlotsForAll = false
    @Published private(set) var savedEmptySlotSizeForAll: DockEmptySlotSize = .full
    @Published private(set) var draftEmptySlotSizeForAll: DockEmptySlotSize = .full
    @Published private(set) var dockRestartMode: DockRestartMode = .fast
    @Published private(set) var settingsShortcut: DockMoverShortcut = .settingsDefault
    @Published private(set) var canUndo = false

    private let service = DockLayoutService()
    private let defaults = UserDefaults.standard
    private let shortcutRegistrar = GlobalShortcutRegistrar()
    private var cancellables: [NSObjectProtocol] = []
    private var applyTask: Task<Void, Never>?
    private var settingsWindowOpener: (() -> Void)?
    private var recentlyQuitBundleIdentifiers: [String: Date] = [:]
    private var undoStack: [UndoState] = []
    private var draftSlotDragState: DraftSlotDragState?
    private var didScheduleDefaultSettingsWindowFrame = false
    private var isRestoring = true
    private let recentlyQuitSuppressionInterval: TimeInterval = 300
    private let undoLimit = 50

    init() {
        isEnabled = defaults.bool(forKey: DefaultsKey.isEnabled)
        settingsShortcut = loadSettingsShortcut()
        dockRestartMode = loadDockRestartMode(forKey: DefaultsKey.dockRestartMode) ?? .fast
        if defaults.integer(forKey: DefaultsKey.dockRestartModeDefaultVersion) < 1 {
            dockRestartMode = .fast
            defaults.set(1, forKey: DefaultsKey.dockRestartModeDefaultVersion)
        }
        loadSlots()
        refreshRunningApps()
        startWatchingWorkspace()
        shortcutRegistrar.action = { [weak self] in
            Task { @MainActor in
                self?.openSettingsWindowFromShortcut()
            }
        }
        let shortcutStatus = shortcutRegistrar.register(settingsShortcut)
        isRestoring = false
        persist()

        if shortcutStatus != noErr {
            status = "Could not register settings shortcut \(settingsShortcut.displayText)"
        }

        if isEnabled {
            scheduleApply(reason: "Started DockMover")
        }
    }

    deinit {
        for cancellable in cancellables {
            NSWorkspace.shared.notificationCenter.removeObserver(cancellable)
        }
    }

    var managedRunningCount: Int {
        let runningIDs = Set(runningApps.map(\.bundleIdentifier))
        return savedSlots.filter { runningIDs.contains($0.bundleIdentifier) }.count
    }

    var draftRunningCount: Int {
        let runningIDs = Set(runningApps.map(\.bundleIdentifier))
        return draftSlots.filter { runningIDs.contains($0.bundleIdentifier) }.count
    }

    var draftPermanentCount: Int {
        draftSlots.filter(\.isPermanent).count
    }

    var savedPermanentCount: Int {
        savedSlots.filter(\.isPermanent).count
    }

    var draftReservedEmptySlotCount: Int {
        let runningIDs = Set(runningApps.map(\.bundleIdentifier))
        return draftSlots.filter {
            !$0.isPermanent
                && !runningIDs.contains($0.bundleIdentifier)
                && (draftReservesEmptySlotsForAll || $0.reservesEmptySlot)
        }.count
    }

    var hasUnsavedChanges: Bool {
        draftSlots != savedSlots
            || draftReservesEmptySlotsForAll != savedReservesEmptySlotsForAll
            || draftEmptySlotSizeForAll != savedEmptySlotSizeForAll
    }

    var unmanagedRunningApps: [RunningDockApp] {
        let managedIDs = Set(draftSlots.map(\.bundleIdentifier))
        return runningApps.filter { !managedIDs.contains($0.bundleIdentifier) }
    }

    func setSettingsWindowOpener(_ opener: @escaping () -> Void) {
        settingsWindowOpener = opener
    }

    func showSettingsWindow(_ openWindow: OpenWindowAction) {
        openWindow(id: "settings")
        bringSettingsWindowForward()
    }

    func configureSettingsWindow(_ window: NSWindow) {
        window.isRestorable = false
        window.contentMinSize = SettingsWindowDefaultFrame.minContentSize

        guard !didScheduleDefaultSettingsWindowFrame else {
            return
        }

        didScheduleDefaultSettingsWindowFrame = true
        Task {
            for delay in [0, 40, 120, 260] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }

                applyDefaultSettingsWindowFrame(to: window)
            }
        }
    }

    func setSettingsShortcut(_ shortcut: DockMoverShortcut) {
        guard shortcut != settingsShortcut else {
            status = "Settings shortcut is already \(shortcut.displayText)"
            return
        }

        let previousShortcut = settingsShortcut
        let shortcutStatus = shortcutRegistrar.register(shortcut)
        guard shortcutStatus == noErr else {
            shortcutRegistrar.register(previousShortcut)
            status = "Could not register \(shortcut.displayText)"
            return
        }

        settingsShortcut = shortcut
        persist()
        status = "Settings shortcut saved as \(shortcut.displayText)"
    }

    private func openSettingsWindowFromShortcut() {
        if let settingsWindowOpener {
            settingsWindowOpener()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
        }

        bringSettingsWindowForward()
    }

    private func bringSettingsWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            for _ in 0..<6 {
                if let settingsWindow {
                    configureSettingsWindow(settingsWindow)
                    settingsWindow.makeKeyAndOrderFront(nil)
                    return
                }

                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func applyDefaultSettingsWindowFrame(to window: NSWindow) {
        if window.isZoomed {
            window.zoom(nil)
        }

        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            window.setContentSize(
                CGSize(width: SettingsWindowDefaultFrame.minContentSize.width, height: SettingsWindowDefaultFrame.contentHeight)
            )
            window.center()
            return
        }

        window.setContentSize(
            CGSize(width: visibleFrame.width, height: SettingsWindowDefaultFrame.contentHeight)
        )

        let frame = window.frame
        window.setFrame(
            NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.midY - frame.height / 2,
                width: visibleFrame.width,
                height: frame.height
            ),
            display: true
        )
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func applyNow() {
        applyTask?.cancel()
        Task {
            await applyDock(reason: "Applied saved Dock", force: true)
        }
    }

    func saveDock() {
        savedSlots = draftSlots
        savedReservesEmptySlotsForAll = draftReservesEmptySlotsForAll
        savedEmptySlotSizeForAll = draftEmptySlotSizeForAll
        clearUndoStack()
        persist()
        status = "Saved fake Dock; use Apply Saved to update the real Dock"
    }

    func restoreLatestBackup() {
        Task {
            isEnabled = false
            isApplying = true
            defer { isApplying = false }

            do {
                let backupURL = try service.restoreLatestBackup(restartMode: dockRestartMode)
                status = "Restored \(backupURL.lastPathComponent)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func addRunningApp(_ app: RunningDockApp) {
        guard !draftSlots.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
            status = "\(app.label) is already managed"
            return
        }

        pushUndoState()
        draftSlots.append(
            DockAppSlot(
                label: app.label,
                bundleIdentifier: app.bundleIdentifier,
                applicationPath: app.applicationPath
            )
        )
        persist()
        status = "Added \(app.label) to the fake Dock"
    }

    func addAppFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            status = "Could not read the selected app bundle identifier"
            return
        }

        let label = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        guard !draftSlots.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            status = "\(label) is already managed"
            return
        }

        pushUndoState()
        draftSlots.append(
            DockAppSlot(
                label: label,
                bundleIdentifier: bundleIdentifier,
                applicationPath: url.path
            )
        )
        persist()
        status = "Added \(label) to the fake Dock"
    }

    func removeSlot(_ slot: DockAppSlot) {
        guard let index = draftSlots.firstIndex(where: { $0.id == slot.id }) else {
            return
        }

        pushUndoState()
        draftSlots.remove(at: index)
        persist()
        status = "Removed \(slot.label) from the fake Dock"
    }

    func moveDraftSlot(sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID,
              let targetIndex = draftSlots.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        reorderDraftSlot(
            sourceID: sourceID,
            toOffset: targetIndex,
            undoMode: .normal,
            statusMessage: { _ in "Reordered fake Dock" }
        )
    }

    func moveDraftSlotToEnd(sourceID: UUID) {
        reorderDraftSlot(
            sourceID: sourceID,
            toOffset: draftSlots.endIndex,
            undoMode: .normal,
            statusMessage: { "Moved \($0.label) to the end of the fake Dock" }
        )
    }

    func beginDraftSlotDrag(sourceID: UUID) {
        guard draftSlots.contains(where: { $0.id == sourceID }) else {
            return
        }

        draftSlotDragState = DraftSlotDragState(initialUndoState: currentUndoState)
    }

    func moveDraftSlotDuringDrag(sourceID: UUID, over targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = draftSlots.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = draftSlots.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let targetOffset = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        reorderDraftSlot(
            sourceID: sourceID,
            toOffset: targetOffset,
            undoMode: .interactiveDrag,
            statusMessage: { _ in "Reordered fake Dock" }
        )
    }

    func moveDraftSlotToEndDuringDrag(sourceID: UUID) {
        reorderDraftSlot(
            sourceID: sourceID,
            toOffset: draftSlots.endIndex,
            undoMode: .interactiveDrag,
            statusMessage: { "Moved \($0.label) to the end of the fake Dock" }
        )
    }

    func endDraftSlotDrag() {
        draftSlotDragState = nil
    }

    func togglePermanent(_ slot: DockAppSlot) {
        guard let index = draftSlots.firstIndex(where: { $0.id == slot.id }) else {
            return
        }

        pushUndoState()
        draftSlots[index].isPermanent.toggle()
        persist()

        let state = draftSlots[index].isPermanent ? "kept in the Dock" : "shown only while running"
        status = "\(draftSlots[index].label) will be \(state)"
    }

    func setReserveEmptySlotsForAll(_ isEnabled: Bool) {
        guard draftReservesEmptySlotsForAll != isEnabled else {
            return
        }

        pushUndoState()
        draftReservesEmptySlotsForAll = isEnabled
        persist()

        status = isEnabled
            ? "Empty slots will be reserved for all non-running fake Dock apps"
            : "Only selected apps will reserve empty slots"
    }

    func setEmptySlotSizeForAll(_ size: DockEmptySlotSize) {
        guard draftEmptySlotSizeForAll != size else {
            return
        }

        pushUndoState()
        draftEmptySlotSizeForAll = size
        persist()
        status = "Global empty slots will use \(size.label.lowercased()) size"
    }

    func setReserveEmptySlot(_ slot: DockAppSlot, size: DockEmptySlotSize?) {
        guard let index = draftSlots.firstIndex(where: { $0.id == slot.id }) else {
            return
        }

        if let size {
            guard !draftSlots[index].reservesEmptySlot || draftSlots[index].reservedEmptySlotSize != size else {
                return
            }
        } else {
            guard draftSlots[index].reservesEmptySlot else {
                return
            }
        }

        pushUndoState()
        if let size {
            draftSlots[index].reservesEmptySlot = true
            draftSlots[index].reservedEmptySlotSize = size
        } else {
            draftSlots[index].reservesEmptySlot = false
        }

        persist()

        if let size {
            status = "\(draftSlots[index].label) will reserve a \(size.label.lowercased()) empty slot"
        } else {
            status = "\(draftSlots[index].label) will collapse when not running"
        }
    }

    func setDockRestartMode(_ mode: DockRestartMode) {
        guard dockRestartMode != mode else {
            return
        }

        pushUndoState()
        dockRestartMode = mode
        persist()
        status = "Dock refresh will use \(mode.statusLabel)"
    }

    func undoLastChange() {
        guard let previousState = undoStack.popLast() else {
            status = "Nothing to undo"
            return
        }

        restore(previousState)
        canUndo = !undoStack.isEmpty
        persist()
        status = "Undid last change"
    }

    func runningState(for slot: DockAppSlot) -> Bool {
        runningApps.contains { $0.bundleIdentifier == slot.bundleIdentifier }
    }

    private func loadSlots() {
        if let data = defaults.data(forKey: DefaultsKey.slots),
           let savedSlots = try? JSONDecoder().decode([DockAppSlot].self, from: data) {
            self.savedSlots = savedSlots
            draftSlots = loadPersistedSlots(forKey: DefaultsKey.draftSlots) ?? savedSlots
            savedReservesEmptySlotsForAll = defaults.bool(forKey: DefaultsKey.reservesEmptySlotsForAll)
            draftReservesEmptySlotsForAll = defaults.object(forKey: DefaultsKey.draftReservesEmptySlotsForAll) as? Bool
                ?? savedReservesEmptySlotsForAll
            savedEmptySlotSizeForAll = loadEmptySlotSize(forKey: DefaultsKey.emptySlotSizeForAll) ?? .full
            draftEmptySlotSizeForAll = loadEmptySlotSize(forKey: DefaultsKey.draftEmptySlotSizeForAll)
                ?? savedEmptySlotSizeForAll
            if hasUnsavedChanges {
                status = "Loaded last fake Dock session"
            }
            return
        }

        do {
            savedSlots = try defaultSlotsFromCurrentDockAndRunningApps()
            draftSlots = savedSlots
            savedReservesEmptySlotsForAll = defaults.bool(forKey: DefaultsKey.reservesEmptySlotsForAll)
            draftReservesEmptySlotsForAll = savedReservesEmptySlotsForAll
            savedEmptySlotSizeForAll = loadEmptySlotSize(forKey: DefaultsKey.emptySlotSizeForAll) ?? .full
            draftEmptySlotSizeForAll = savedEmptySlotSizeForAll
            status = "Started fake Dock from current Dock and running apps"
        } catch {
            savedSlots = []
            draftSlots = []
            savedReservesEmptySlotsForAll = false
            draftReservesEmptySlotsForAll = false
            savedEmptySlotSizeForAll = .full
            draftEmptySlotSizeForAll = .full
            status = error.localizedDescription
        }
    }

    private func persist() {
        guard !isRestoring else { return }
        defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)

        if let data = try? JSONEncoder().encode(savedSlots) {
            defaults.set(data, forKey: DefaultsKey.slots)
        }

        if let data = try? JSONEncoder().encode(draftSlots) {
            defaults.set(data, forKey: DefaultsKey.draftSlots)
        }

        defaults.set(savedReservesEmptySlotsForAll, forKey: DefaultsKey.reservesEmptySlotsForAll)
        defaults.set(draftReservesEmptySlotsForAll, forKey: DefaultsKey.draftReservesEmptySlotsForAll)
        defaults.set(savedEmptySlotSizeForAll.rawValue, forKey: DefaultsKey.emptySlotSizeForAll)
        defaults.set(draftEmptySlotSizeForAll.rawValue, forKey: DefaultsKey.draftEmptySlotSizeForAll)
        defaults.set(dockRestartMode.rawValue, forKey: DefaultsKey.dockRestartMode)
        persistSettingsShortcut()
    }

    private func loadPersistedSlots(forKey key: String) -> [DockAppSlot]? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode([DockAppSlot].self, from: data)
    }

    private func loadEmptySlotSize(forKey key: String) -> DockEmptySlotSize? {
        guard let rawValue = defaults.string(forKey: key) else {
            return nil
        }

        return DockEmptySlotSize(rawValue: rawValue)
    }

    private func loadDockRestartMode(forKey key: String) -> DockRestartMode? {
        guard let rawValue = defaults.string(forKey: key) else {
            return nil
        }

        return DockRestartMode(rawValue: rawValue)
    }

    private func loadSettingsShortcut() -> DockMoverShortcut {
        guard let data = defaults.data(forKey: DefaultsKey.settingsShortcut),
              let shortcut = try? JSONDecoder().decode(DockMoverShortcut.self, from: data) else {
            return .settingsDefault
        }

        return shortcut
    }

    private func persistSettingsShortcut() {
        if let data = try? JSONEncoder().encode(settingsShortcut) {
            defaults.set(data, forKey: DefaultsKey.settingsShortcut)
        }
    }

    private var currentUndoState: UndoState {
        UndoState(
            draftSlots: draftSlots,
            draftReservesEmptySlotsForAll: draftReservesEmptySlotsForAll,
            draftEmptySlotSizeForAll: draftEmptySlotSizeForAll,
            dockRestartMode: dockRestartMode
        )
    }

    private func pushUndoState() {
        pushUndoState(currentUndoState)
    }

    private func pushUndoState(_ state: UndoState) {
        guard undoStack.last != state else {
            return
        }

        undoStack.append(state)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        canUndo = true
    }

    private func restore(_ state: UndoState) {
        draftSlots = state.draftSlots
        draftReservesEmptySlotsForAll = state.draftReservesEmptySlotsForAll
        draftEmptySlotSizeForAll = state.draftEmptySlotSizeForAll
        dockRestartMode = state.dockRestartMode
    }

    private func clearUndoStack() {
        undoStack.removeAll()
        canUndo = false
    }

    @discardableResult
    private func reorderDraftSlot(
        sourceID: UUID,
        toOffset rawTargetOffset: Int,
        undoMode: DraftSlotReorderUndoMode,
        statusMessage: (DockAppSlot) -> String
    ) -> DockAppSlot? {
        guard let sourceIndex = draftSlots.firstIndex(where: { $0.id == sourceID }) else {
            return nil
        }

        let targetOffset = min(max(rawTargetOffset, draftSlots.startIndex), draftSlots.endIndex)
        let adjustedTargetIndex = sourceIndex < targetOffset ? targetOffset - 1 : targetOffset
        guard adjustedTargetIndex != sourceIndex else {
            return nil
        }

        switch undoMode {
        case .normal:
            pushUndoState()
        case .interactiveDrag:
            pushDraftSlotDragUndoStateIfNeeded()
        }

        let movedSlot = draftSlots.remove(at: sourceIndex)
        draftSlots.insert(movedSlot, at: adjustedTargetIndex)
        persist()
        status = statusMessage(movedSlot)
        return movedSlot
    }

    private func pushDraftSlotDragUndoStateIfNeeded() {
        if draftSlotDragState == nil {
            draftSlotDragState = DraftSlotDragState(initialUndoState: currentUndoState)
        }

        guard draftSlotDragState?.didPushUndo == false,
              let initialUndoState = draftSlotDragState?.initialUndoState else {
            return
        }

        pushUndoState(initialUndoState)
        draftSlotDragState?.didPushUndo = true
    }

    private var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "settings" || $0.title == "DockMover" }
    }

    private func startWatchingWorkspace() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        cancellables.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleWorkspaceLaunch(notification: notification)
                }
            }
        )

        cancellables.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleWorkspaceQuit(notification: notification)
                }
            }
        )
    }

    private func handleWorkspaceLaunch(notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleIdentifier = app?.bundleIdentifier
        clearRecentlyQuitBundleIdentifier(bundleIdentifier)

        let isSavedFakeDockApp = bundleIdentifier.map { id in
            savedSlots.contains { $0.bundleIdentifier == id }
        } ?? true

        refreshRunningApps()

        guard isSavedFakeDockApp else {
            if let label = app?.localizedName {
                status = "\(label) is not in the saved fake Dock; leaving it to macOS"
            }
            return
        }

        let label = app?.localizedName ?? "Managed app"
        scheduleApply(reason: "\(label): app launched")
    }

    private func handleWorkspaceQuit(notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleIdentifier = app?.bundleIdentifier
        let isSavedFakeDockApp = bundleIdentifier.map { id in
            savedSlots.contains { $0.bundleIdentifier == id }
        } ?? true

        if isSavedFakeDockApp {
            rememberRecentlyQuitBundleIdentifier(bundleIdentifier)
        }

        refreshRunningApps()

        guard isSavedFakeDockApp else {
            if let label = app?.localizedName {
                status = "\(label) quit outside the saved fake Dock; leaving it to macOS"
            }
            return
        }

        let label = app?.localizedName ?? "Managed app"
        scheduleApply(reason: "\(label): app quit")
    }

    private func refreshRunningApps() {
        runningApps = activeRunningApps()
    }

    private func activeRunningApps() -> [RunningDockApp] {
        pruneRecentlyQuitBundleIdentifiers()
        return currentRunningApps().filter { recentlyQuitBundleIdentifiers[$0.bundleIdentifier] == nil }
    }

    private func currentRunningApps() -> [RunningDockApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleIdentifier = app.bundleIdentifier else { return nil }
                return RunningDockApp(
                    label: app.localizedName ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    applicationPath: app.bundleURL?.path
                )
            }
            .uniquedByBundleIdentifier()
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func defaultSlotsFromCurrentDockAndRunningApps() throws -> [DockAppSlot] {
        var slots = try service.currentDockSlots()
        var existingBundleIdentifiers = Set(slots.map(\.bundleIdentifier))

        for app in activeRunningApps() where existingBundleIdentifiers.insert(app.bundleIdentifier).inserted {
            slots.append(
                DockAppSlot(
                    label: app.label,
                    bundleIdentifier: app.bundleIdentifier,
                    applicationPath: app.applicationPath
                )
            )
        }

        return slots
    }

    private func rememberRecentlyQuitBundleIdentifier(_ bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        recentlyQuitBundleIdentifiers[bundleIdentifier] = Date()
    }

    private func clearRecentlyQuitBundleIdentifier(_ bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        recentlyQuitBundleIdentifiers.removeValue(forKey: bundleIdentifier)
    }

    private func pruneRecentlyQuitBundleIdentifiers() {
        let now = Date()
        let expiredBundleIdentifiers = recentlyQuitBundleIdentifiers.compactMap { bundleIdentifier, date in
            now.timeIntervalSince(date) > recentlyQuitSuppressionInterval ? bundleIdentifier : nil
        }

        for bundleIdentifier in expiredBundleIdentifiers {
            recentlyQuitBundleIdentifiers.removeValue(forKey: bundleIdentifier)
        }
    }

    private func scheduleApply(reason: String) {
        guard isEnabled else { return }

        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.waitUntilDockIsIdle()
            guard !Task.isCancelled else { return }
            await self?.applyDock(reason: reason)
        }
    }

    private func waitUntilDockIsIdle() async {
        var hasReportedWait = false

        while isDockLikelyActive {
            if !hasReportedWait {
                status = "Waiting for Dock to be idle before refreshing"
                hasReportedWait = true
            }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
    }

    private var isDockLikelyActive: Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock" {
            return true
        }

        return isMouseInDockInteractionArea
    }

    private var isMouseInDockInteractionArea: Bool {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return false
        }

        let frame = screen.frame
        let margin: CGFloat = 110

        switch dockOrientation {
        case "left":
            return mouseLocation.x <= frame.minX + margin
        case "right":
            return mouseLocation.x >= frame.maxX - margin
        default:
            return mouseLocation.y <= frame.minY + margin
        }
    }

    private var dockOrientation: String {
        CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
    }

    private func applyDock(reason: String, force: Bool = false) async {
        guard isEnabled || force else {
            status = "Disabled"
            return
        }

        isApplying = true
        defer { isApplying = false }

        do {
            refreshRunningApps()
            let result = try service.apply(
                slots: savedSlots,
                runningApps: runningApps,
                reserveEmptySlotsForAll: savedReservesEmptySlotsForAll,
                emptySlotSizeForAll: savedEmptySlotSizeForAll,
                restartMode: dockRestartMode
            )
            let runningIDs = Set(runningApps.map(\.bundleIdentifier))
            let placedCount = savedSlots.filter {
                $0.isPermanent
                    || runningIDs.contains($0.bundleIdentifier)
                    || savedReservesEmptySlotsForAll
                    || $0.reservesEmptySlot
            }.count
            let reservedCount = savedSlots.filter {
                !$0.isPermanent
                    && !runningIDs.contains($0.bundleIdentifier)
                    && (savedReservesEmptySlotsForAll || $0.reservesEmptySlot)
            }.count

            status = "\(reason): placed \(placedCount) saved slots, \(reservedCount) empty, backup \(result.backupURL.lastPathComponent)"
        } catch {
            status = error.localizedDescription
        }
    }
}

private enum DefaultsKey {
    static let isEnabled = "DockMover.isEnabled"
    static let slots = "DockMover.slots"
    static let draftSlots = "DockMover.draftSlots"
    static let reservesEmptySlotsForAll = "DockMover.reservesEmptySlotsForAll"
    static let draftReservesEmptySlotsForAll = "DockMover.draftReservesEmptySlotsForAll"
    static let emptySlotSizeForAll = "DockMover.emptySlotSizeForAll"
    static let draftEmptySlotSizeForAll = "DockMover.draftEmptySlotSizeForAll"
    static let dockRestartMode = "DockMover.dockRestartMode"
    static let dockRestartModeDefaultVersion = "DockMover.dockRestartModeDefaultVersion"
    static let settingsShortcut = "DockMover.settingsShortcut"
}

private struct UndoState: Equatable {
    let draftSlots: [DockAppSlot]
    let draftReservesEmptySlotsForAll: Bool
    let draftEmptySlotSizeForAll: DockEmptySlotSize
    let dockRestartMode: DockRestartMode
}

private enum DraftSlotReorderUndoMode {
    case normal
    case interactiveDrag
}

private struct DraftSlotDragState {
    let initialUndoState: UndoState
    var didPushUndo = false
}

private extension Array where Element == RunningDockApp {
    func uniquedByBundleIdentifier() -> [RunningDockApp] {
        var seen = Set<String>()
        return filter { app in
            seen.insert(app.bundleIdentifier).inserted
        }
    }
}
