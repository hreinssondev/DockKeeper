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
    @Published private(set) var allowStackableGaps = false
    @Published private(set) var cpuMode: DockMoverCPUMode = .defaultMode
    @Published private(set) var settingsShortcut: DockMoverShortcut = .settingsDefault
    @Published private(set) var canUndo = false

    private let service = DockLayoutService()
    private let defaults = UserDefaults.standard
    private let shortcutRegistrar = GlobalShortcutRegistrar()
    private var cancellables: [NSObjectProtocol] = []
    private var applyTask: Task<Void, Never>?
    private var pendingApplyReason: String?
    private var runningAppsPollTask: Task<Void, Never>?
    private var lowCPUReconcileTask: Task<Void, Never>?
    private var settingsWindowOpener: (() -> Void)?
    private var recentlyQuitBundleIdentifiers: [String: Date] = [:]
    private var lastManagedRunningBundleIdentifiers: Set<String> = []
    private var savedSlotLookupCache: SavedSlotLookup?
    private var undoStack: [UndoState] = []
    private var draftSlotDragState: DraftSlotDragState?
    private var didScheduleDefaultSettingsWindowFrame = false
    private var isRestoring = true
    private let recentlyQuitSuppressionInterval: TimeInterval = 300
    private let recentlyQuitReopenDetectionDelay: TimeInterval = 2
    private let lowCPUReconcileDelay: TimeInterval = 2.5
    private let lowCPUStaleDockCheckInterval: TimeInterval = 5
    private let applyDebounceInterval: TimeInterval = 0.25
    private let runningAppsPollInterval: TimeInterval = 1.0
    private let dockIdleCheckInterval: TimeInterval = 0.12
    private let dockIdleWaitLimit: TimeInterval = 2
    private let undoLimit = 50

    init() {
        isEnabled = defaults.bool(forKey: DefaultsKey.isEnabled)
        settingsShortcut = loadSettingsShortcut()
        dockRestartMode = loadDockRestartMode(forKey: DefaultsKey.dockRestartMode) ?? .fast
        allowStackableGaps = defaults.bool(forKey: DefaultsKey.allowStackableGaps)
        cpuMode = loadCPUMode(forKey: DefaultsKey.cpuMode) ?? .defaultMode
        if defaults.integer(forKey: DefaultsKey.dockRestartModeDefaultVersion) < 1 {
            dockRestartMode = .fast
            defaults.set(1, forKey: DefaultsKey.dockRestartModeDefaultVersion)
        }
        loadSlots()
        refreshRunningApps()
        lastManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers
        startWatchingWorkspace()
        configureRunningAppsPolling()
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
        runningAppsPollTask?.cancel()
        lowCPUReconcileTask?.cancel()
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
        lastManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers
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

    func setAllowStackableGaps(_ isAllowed: Bool) {
        guard allowStackableGaps != isAllowed else {
            return
        }

        pushUndoState()
        allowStackableGaps = isAllowed
        persist()
        status = isAllowed
            ? "Half-size empty slots can stack into larger gaps"
            : "Adjacent half-size empty slots will collapse to one half gap"
        scheduleApply(reason: "Changed stackable gaps")
    }

    func setCPUMode(_ mode: DockMoverCPUMode) {
        guard cpuMode != mode else {
            return
        }

        pushUndoState()
        cpuMode = mode
        configureRunningAppsPolling()
        refreshRunningApps(forcePublish: true)
        lastManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers
        persist()
        status = mode.statusLabel
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
        defaults.set(allowStackableGaps, forKey: DefaultsKey.allowStackableGaps)
        defaults.set(cpuMode.rawValue, forKey: DefaultsKey.cpuMode)
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

    private func loadCPUMode(forKey key: String) -> DockMoverCPUMode? {
        guard let rawValue = defaults.string(forKey: key) else {
            return nil
        }

        return DockMoverCPUMode(rawValue: rawValue)
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
            dockRestartMode: dockRestartMode,
            allowStackableGaps: allowStackableGaps,
            cpuMode: cpuMode
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
        allowStackableGaps = state.allowStackableGaps
        cpuMode = state.cpuMode
        configureRunningAppsPolling()
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
        clearRecentlyQuitBundleIdentifiers(for: app, includeContainedHelpers: true)

        let isSavedFakeDockApp = isSavedFakeDockApp(app, includeContainedHelpers: true)

        refreshRunningApps()

        guard isSavedFakeDockApp else {
            if let label = app?.localizedName {
                status = "\(label) is not in the saved fake Dock; leaving it to macOS"
            }
            return
        }

        let label = app?.localizedName ?? "Managed app"
        lastManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers
        scheduleApply(reason: "\(label): app launched")
        scheduleLowCPUReconcile(reason: "\(label): launch settled")
    }

    private func handleWorkspaceQuit(notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let isSavedFakeDockApp = isSavedFakeDockApp(app, includeContainedHelpers: true)

        if isSavedFakeDockApp {
            rememberRecentlyQuitBundleIdentifiers(for: app, includeContainedHelpers: true)
        }

        refreshRunningApps()

        guard isSavedFakeDockApp else {
            if let label = app?.localizedName {
                status = "\(label) quit outside the saved fake Dock; leaving it to macOS"
            }
            return
        }

        let label = app?.localizedName ?? "Managed app"
        lastManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers
        scheduleApply(reason: "\(label): app quit")
        scheduleLowCPUReconcile(reason: "\(label): quit settled")
    }

    @discardableResult
    private func refreshRunningApps(forcePublish: Bool = true) -> Bool {
        let nextRunningApps = activeRunningApps()
        guard forcePublish || nextRunningApps != runningApps else {
            return false
        }

        runningApps = nextRunningApps
        return true
    }

    private var managedRunningBundleIdentifiers: Set<String> {
        managedRunningBundleIdentifiers(in: runningApps)
    }

    private func managedRunningBundleIdentifiers(in apps: [RunningDockApp]) -> Set<String> {
        let managedIDs = Set(savedSlots.filter { !$0.isPermanent }.map(\.bundleIdentifier))
        return Set(apps.map(\.bundleIdentifier)).intersection(managedIDs)
    }

    private func configureRunningAppsPolling() {
        runningAppsPollTask?.cancel()
        runningAppsPollTask = nil
        lowCPUReconcileTask?.cancel()
        lowCPUReconcileTask = nil
        guard cpuMode.usesPolling else {
            startLowCPUStaleDockChecking()
            return
        }

        startPollingRunningApps()
    }

    private func startPollingRunningApps() {
        let pollInterval = runningAppsPollInterval
        runningAppsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1_000)))
                guard !Task.isCancelled else { return }

                self?.reconcileRunningAppsFromPoll()
            }
        }
    }

    private func startLowCPUStaleDockChecking() {
        let checkInterval = lowCPUStaleDockCheckInterval
        runningAppsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(checkInterval * 1_000)))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.reconcileStaleDockTilesForLowCPU()
                }
            }
        }
    }

    private func reconcileRunningAppsFromPoll() {
        let nextRunningApps = activeRunningApps()
        let shouldForcePublish = !cpuMode.publishesRunningAppsOnlyWhenChanged
        if shouldForcePublish || nextRunningApps != runningApps {
            runningApps = nextRunningApps
        }

        let currentManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers(in: nextRunningApps)

        guard currentManagedRunningBundleIdentifiers != lastManagedRunningBundleIdentifiers else {
            return
        }

        lastManagedRunningBundleIdentifiers = currentManagedRunningBundleIdentifiers
        scheduleApply(reason: "Running apps changed")
    }

    private func scheduleLowCPUReconcile(reason: String) {
        guard cpuMode == .lowCPU else { return }

        lowCPUReconcileTask?.cancel()
        let delay = lowCPUReconcileDelay
        lowCPUReconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.reconcileRunningAppsFromLowCPUEvent(reason: reason)
            }
        }
    }

    private func reconcileRunningAppsFromLowCPUEvent(reason: String) {
        let nextRunningApps = activeRunningApps()
        let previousManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers(in: runningApps)
        let currentManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers(in: nextRunningApps)

        guard nextRunningApps != runningApps ||
              currentManagedRunningBundleIdentifiers != previousManagedRunningBundleIdentifiers else {
            return
        }

        runningApps = nextRunningApps
        lastManagedRunningBundleIdentifiers = currentManagedRunningBundleIdentifiers

        if currentManagedRunningBundleIdentifiers != previousManagedRunningBundleIdentifiers {
            scheduleApply(reason: reason)
        }
    }

    private func reconcileStaleDockTilesForLowCPU() {
        guard cpuMode == .lowCPU, isEnabled else { return }

        refreshRunningApps(forcePublish: false)
        guard hasStaleManagedDockTiles() else { return }

        scheduleApply(reason: "Low CPU stale Dock cleanup")
    }

    private func hasStaleManagedDockTiles() -> Bool {
        let runningBundleIdentifiers = Set(runningApps.map(\.bundleIdentifier))
        let staleManagedBundleIdentifiers = Set(savedSlots.compactMap { slot -> String? in
            guard !slot.isPermanent,
                  !slot.reservesEmptySlot,
                  !savedReservesEmptySlotsForAll,
                  !runningBundleIdentifiers.contains(slot.bundleIdentifier) else {
                return nil
            }

            return slot.bundleIdentifier
        })

        guard !staleManagedBundleIdentifiers.isEmpty,
              let dockBundleIdentifiers = try? service.currentPersistentAppBundleIdentifiers() else {
            return false
        }

        return !dockBundleIdentifiers.isDisjoint(with: staleManagedBundleIdentifiers)
    }

    private func activeRunningApps() -> [RunningDockApp] {
        pruneRecentlyQuitBundleIdentifiers()
        clearRecentlyQuitBundleIdentifiersForOpenSavedApps()
        return currentRunningApps().filter { recentlyQuitBundleIdentifiers[$0.bundleIdentifier] == nil }
    }

    private func currentRunningApps() -> [RunningDockApp] {
        NSWorkspace.shared.runningApplications
            .compactMap(runningDockApp)
            .uniquedByBundleIdentifier()
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func runningDockApp(from app: NSRunningApplication) -> RunningDockApp? {
        guard app.activationPolicy == .regular else { return nil }

        if let slot = savedSlot(forRunningApplication: app) {
            return RunningDockApp(
                label: slot.label,
                bundleIdentifier: slot.bundleIdentifier,
                applicationPath: slot.applicationPath ?? app.bundleURL?.path
            )
        }

        if let slot = savedSlot(forRunningApplication: app, includeContainedHelpers: true),
           slotAllowsContainedRunningApp(slot) {
            return RunningDockApp(
                label: slot.label,
                bundleIdentifier: slot.bundleIdentifier,
                applicationPath: slot.applicationPath ?? app.bundleURL?.path
            )
        }

        guard !isContainedInSavedApp(app) else { return nil }

        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        return RunningDockApp(
            label: app.localizedName ?? bundleIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationPath: app.bundleURL?.path
        )
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

    private func isSavedFakeDockApp(_ app: NSRunningApplication?, includeContainedHelpers: Bool = false) -> Bool {
        guard let app else { return true }
        guard app.bundleIdentifier != nil else { return true }

        return savedSlot(forRunningApplication: app, includeContainedHelpers: includeContainedHelpers) != nil
    }

    private func savedSlot(
        forRunningApplication app: NSRunningApplication,
        includeContainedHelpers: Bool = false
    ) -> DockAppSlot? {
        if cpuMode.usesCachedSlotLookup {
            return cachedSavedSlotLookup().slot(
                forRunningApplication: app,
                includeContainedHelpers: includeContainedHelpers
            )
        }

        if let bundleIdentifier = app.bundleIdentifier,
           let slot = savedSlots.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return slot
        }

        guard let runningApplicationPath = app.bundleURL?.standardizedFileURL.path else {
            return nil
        }

        let slotsByLongestPath = savedSlots
            .compactMap { slot -> (slot: DockAppSlot, path: String)? in
                guard let applicationPath = slot.applicationPath else { return nil }
                let path = URL(fileURLWithPath: applicationPath, isDirectory: true).standardizedFileURL.path
                return (slot, path)
            }
            .sorted { $0.path.count > $1.path.count }

        for candidate in slotsByLongestPath {
            if runningApplicationPath == candidate.path {
                return candidate.slot
            }

            if includeContainedHelpers,
               runningApplicationPath.hasPrefix(candidate.path + "/") {
                return candidate.slot
            }
        }

        return nil
    }

    private func isContainedInSavedApp(_ app: NSRunningApplication) -> Bool {
        savedSlot(forRunningApplication: app, includeContainedHelpers: true) != nil
    }

    private func slotAllowsContainedRunningApp(_ slot: DockAppSlot) -> Bool {
        if cpuMode.usesCachedSlotLookup {
            return cachedSavedSlotLookup().allowsContainedRunningApp(slot)
        }

        guard let applicationPath = slot.applicationPath,
              let bundle = Bundle(url: URL(fileURLWithPath: applicationPath, isDirectory: true)) else {
            return false
        }

        return bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
            || bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true
    }

    private func cachedSavedSlotLookup() -> SavedSlotLookup {
        if let savedSlotLookupCache,
           savedSlotLookupCache.slots == savedSlots {
            return savedSlotLookupCache
        }

        let lookup = SavedSlotLookup(slots: savedSlots)
        savedSlotLookupCache = lookup
        return lookup
    }

    private func bundleIdentifiers(
        for app: NSRunningApplication?,
        includeContainedHelpers: Bool = false
    ) -> Set<String> {
        guard let app else { return [] }

        var bundleIdentifiers = Set<String>()
        if let bundleIdentifier = app.bundleIdentifier {
            bundleIdentifiers.insert(bundleIdentifier)
        }

        if let slot = savedSlot(
            forRunningApplication: app,
            includeContainedHelpers: includeContainedHelpers
        ) {
            bundleIdentifiers.insert(slot.bundleIdentifier)
        }

        return bundleIdentifiers
    }

    private func rememberRecentlyQuitBundleIdentifiers(
        for app: NSRunningApplication?,
        includeContainedHelpers: Bool = false
    ) {
        for bundleIdentifier in bundleIdentifiers(for: app, includeContainedHelpers: includeContainedHelpers) {
            recentlyQuitBundleIdentifiers[bundleIdentifier] = Date()
        }
    }

    @discardableResult
    private func clearRecentlyQuitBundleIdentifiers(
        for app: NSRunningApplication?,
        includeContainedHelpers: Bool = false
    ) -> Bool {
        var didClear = false

        for bundleIdentifier in bundleIdentifiers(
            for: app,
            includeContainedHelpers: includeContainedHelpers
        ) {
            if recentlyQuitBundleIdentifiers.removeValue(forKey: bundleIdentifier) != nil {
                didClear = true
            }
        }

        return didClear
    }

    private func clearRecentlyQuitBundleIdentifiersForOpenSavedApps() {
        let savedBundleIdentifiers = Set(savedSlots.map(\.bundleIdentifier))
        let now = Date()
        let openSavedBundleIdentifiers = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular,
                  let bundleIdentifier = app.bundleIdentifier,
                  savedBundleIdentifiers.contains(bundleIdentifier) else {
                return nil
            }

            return bundleIdentifier
        }

        for bundleIdentifier in openSavedBundleIdentifiers {
            if let quitDate = recentlyQuitBundleIdentifiers[bundleIdentifier],
               now.timeIntervalSince(quitDate) < recentlyQuitReopenDetectionDelay {
                continue
            }

            recentlyQuitBundleIdentifiers.removeValue(forKey: bundleIdentifier)
        }
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

        guard !isApplying else {
            pendingApplyReason = reason
            return
        }

        applyTask?.cancel()
        let debounceInterval = applyDebounceInterval
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(debounceInterval * 1_000)))
            guard !Task.isCancelled else { return }
            await self?.waitUntilDockIsIdle()
            guard !Task.isCancelled else { return }
            await self?.applyDock(reason: reason)
        }
    }

    private func waitUntilDockIsIdle() async {
        var hasReportedWait = false
        let idleCheckInterval = dockIdleCheckInterval
        let waitStartedAt = Date()

        while isDockLikelyActive {
            guard Date().timeIntervalSince(waitStartedAt) < dockIdleWaitLimit else {
                break
            }

            if !hasReportedWait {
                status = "Waiting for Dock to be idle before refreshing"
                hasReportedWait = true
            }

            try? await Task.sleep(for: .milliseconds(Int(idleCheckInterval * 1_000)))
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
        defer {
            isApplying = false

            if let pendingReason = pendingApplyReason {
                pendingApplyReason = nil
                scheduleApply(reason: pendingReason)
            }
        }

        do {
            refreshRunningApps()
            lastManagedRunningBundleIdentifiers = managedRunningBundleIdentifiers
            let result = try service.apply(
                slots: savedSlots,
                runningApps: runningApps,
                reserveEmptySlotsForAll: savedReservesEmptySlotsForAll,
                emptySlotSizeForAll: savedEmptySlotSizeForAll,
                allowStackableGaps: allowStackableGaps,
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

            if let backupURL = result.backupURL {
                status = "\(reason): placed \(placedCount) saved slots, \(reservedCount) empty, backup \(backupURL.lastPathComponent)"
            } else {
                status = "\(reason): Dock already matched \(placedCount) saved slots, \(reservedCount) empty"
            }
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
    static let allowStackableGaps = "DockMover.allowStackableGaps"
    static let cpuMode = "DockMover.cpuMode"
    static let settingsShortcut = "DockMover.settingsShortcut"
}

enum DockMoverCPUMode: String, CaseIterable, Identifiable {
    case defaultMode = "default"
    case whenChanged = "whenChanged"
    case cache = "cache"
    case lowCPU = "lowCPU"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultMode:
            "Default"
        case .whenChanged:
            "When changed"
        case .cache:
            "Cache"
        case .lowCPU:
            "Low CPU"
        }
    }

    var usesPolling: Bool {
        self != .lowCPU
    }

    var publishesRunningAppsOnlyWhenChanged: Bool {
        switch self {
        case .whenChanged, .cache:
            true
        case .defaultMode, .lowCPU:
            false
        }
    }

    var usesCachedSlotLookup: Bool {
        self == .cache
    }

    var statusLabel: String {
        switch self {
        case .defaultMode:
            "CPU mode set to Default; DockMover will poll running apps every second"
        case .whenChanged:
            "CPU mode set to When changed; DockMover will publish running apps only after changes"
        case .cache:
            "CPU mode set to Cache; DockMover will publish only changes and reuse app lookup data"
        case .lowCPU:
            "CPU mode set to Low CPU; DockMover will rely on app launch and quit events"
        }
    }
}

private struct SavedSlotLookup {
    let slots: [DockAppSlot]
    private let slotsByBundleIdentifier: [String: DockAppSlot]
    private let slotsByLongestPath: [(slot: DockAppSlot, path: String)]
    private let containedRunningAppAllowedSlotIDs: Set<UUID>

    init(slots: [DockAppSlot]) {
        self.slots = slots

        var slotsByBundleIdentifier: [String: DockAppSlot] = [:]
        for slot in slots where slotsByBundleIdentifier[slot.bundleIdentifier] == nil {
            slotsByBundleIdentifier[slot.bundleIdentifier] = slot
        }
        self.slotsByBundleIdentifier = slotsByBundleIdentifier

        slotsByLongestPath = slots
            .compactMap { slot -> (slot: DockAppSlot, path: String)? in
                guard let applicationPath = slot.applicationPath else { return nil }
                let path = URL(fileURLWithPath: applicationPath, isDirectory: true).standardizedFileURL.path
                return (slot, path)
            }
            .sorted { $0.path.count > $1.path.count }

        containedRunningAppAllowedSlotIDs = Set(slots.compactMap { slot in
            guard let applicationPath = slot.applicationPath,
                  let bundle = Bundle(url: URL(fileURLWithPath: applicationPath, isDirectory: true)) else {
                return nil
            }

            let allowsContainedRunningApp = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
                || bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true
            guard allowsContainedRunningApp else { return nil }

            return slot.id
        })
    }

    func slot(
        forRunningApplication app: NSRunningApplication,
        includeContainedHelpers: Bool = false
    ) -> DockAppSlot? {
        if let bundleIdentifier = app.bundleIdentifier,
           let slot = slotsByBundleIdentifier[bundleIdentifier] {
            return slot
        }

        guard let runningApplicationPath = app.bundleURL?.standardizedFileURL.path else {
            return nil
        }

        for candidate in slotsByLongestPath {
            if runningApplicationPath == candidate.path {
                return candidate.slot
            }

            if includeContainedHelpers,
               runningApplicationPath.hasPrefix(candidate.path + "/") {
                return candidate.slot
            }
        }

        return nil
    }

    func allowsContainedRunningApp(_ slot: DockAppSlot) -> Bool {
        containedRunningAppAllowedSlotIDs.contains(slot.id)
    }
}

private struct UndoState: Equatable {
    let draftSlots: [DockAppSlot]
    let draftReservesEmptySlotsForAll: Bool
    let draftEmptySlotSizeForAll: DockEmptySlotSize
    let dockRestartMode: DockRestartMode
    let allowStackableGaps: Bool
    let cpuMode: DockMoverCPUMode
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
