import AppKit
import Foundation

struct DockTileSnapshot {
    let label: String
    let bundleIdentifier: String
    let applicationPath: String?
    let tile: [String: Any]
}

struct DockApplyResult {
    let backupURL: URL
}

enum DockRestartMode: String, CaseIterable, Identifiable {
    case normal
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal:
            "Normal"
        case .fast:
            "Fast"
        }
    }

    var statusLabel: String {
        switch self {
        case .normal:
            "normal restart"
        case .fast:
            "fast restart"
        }
    }
}

enum DockLayoutError: LocalizedError {
    case dockPlistMissing(URL)
    case invalidDockPlist
    case missingApplicationPath(DockAppSlot)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .dockPlistMissing(let url):
            "Dock preferences were not found at \(url.path)."
        case .invalidDockPlist:
            "Dock preferences could not be read."
        case .missingApplicationPath(let slot):
            "\(slot.label) needs an application path before DockMover can create its Dock tile."
        case .processFailed(let message):
            message
        }
    }
}

final class DockLayoutService {
    private let dockDomain = "com.apple.dock"
    private let fileManager = FileManager.default

    var dockPlistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    }

    var applicationSupportURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockMover", isDirectory: true)
    }

    func currentDockSlots() throws -> [DockAppSlot] {
        try readPersistentAppTiles().map {
            DockAppSlot(
                label: $0.label,
                bundleIdentifier: $0.bundleIdentifier,
                applicationPath: $0.applicationPath,
                isPermanent: true
            )
        }
    }

    func apply(
        slots: [DockAppSlot],
        runningApps: [RunningDockApp],
        reserveEmptySlotsForAll: Bool,
        emptySlotSizeForAll: DockEmptySlotSize,
        restartMode: DockRestartMode
    ) throws -> DockApplyResult {
        var plist = try readDockPlist()
        let existingTiles = persistentAppTiles(from: plist)
        var existingByBundleID: [String: [String: Any]] = [:]
        for tile in existingTiles where existingByBundleID[tile.bundleIdentifier] == nil {
            existingByBundleID[tile.bundleIdentifier] = tile.tile
        }

        let runningByBundleID = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.bundleIdentifier, $0) })

        let nextTiles = try slots.compactMap { slot -> [String: Any]? in
            let runningApp = runningByBundleID[slot.bundleIdentifier]
            let shouldReserveEmptySlot = reserveEmptySlotsForAll || slot.reservesEmptySlot
            let emptySlotSize = slot.reservesEmptySlot ? slot.reservedEmptySlotSize : emptySlotSizeForAll
            guard slot.isPermanent || runningApp != nil || shouldReserveEmptySlot else {
                return nil
            }

            guard slot.isPermanent || runningApp != nil else {
                return makeSpacerTile(size: emptySlotSize)
            }

            if let existingTile = existingByBundleID[slot.bundleIdentifier] {
                return existingTile
            }

            return try makeTile(for: slot, runningApp: runningApp)
        }

        let backupURL = try backupCurrentDock()
        plist["persistent-apps"] = nextTiles
        plist["show-recents"] = false
        try importDockPlist(plist)
        try restartDock(mode: restartMode)
        return DockApplyResult(backupURL: backupURL)
    }

    func backupCurrentDock() throws -> URL {
        try ensureApplicationSupport()

        guard fileManager.fileExists(atPath: dockPlistURL.path) else {
            throw DockLayoutError.dockPlistMissing(dockPlistURL)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = applicationSupportURL
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("com.apple.dock.\(formatter.string(from: Date())).plist")

        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: dockPlistURL, to: backupURL)
        return backupURL
    }

    func restoreLatestBackup(restartMode: DockRestartMode) throws -> URL {
        let backupDirectory = applicationSupportURL.appendingPathComponent("Backups", isDirectory: true)
        let backups = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "plist" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }

        guard let latest = backups.first else {
            throw DockLayoutError.processFailed("No DockMover backup exists yet.")
        }

        try runProcess("/usr/bin/defaults", arguments: ["import", dockDomain, latest.path])
        try restartDock(mode: restartMode)
        return latest
    }

    func readPersistentAppTiles() throws -> [DockTileSnapshot] {
        let plist = try readDockPlist()
        return persistentAppTiles(from: plist)
    }

    private func persistentAppTiles(from plist: [String: Any]) -> [DockTileSnapshot] {
        let tiles = plist["persistent-apps"] as? [[String: Any]] ?? []

        return tiles.compactMap { tile in
            guard let tileData = tile["tile-data"] as? [String: Any],
                  let bundleIdentifier = tileData["bundle-identifier"] as? String else {
                return nil
            }

            let label = tileData["file-label"] as? String ?? bundleIdentifier
            let applicationPath = applicationPath(from: tileData)
            return DockTileSnapshot(
                label: label,
                bundleIdentifier: bundleIdentifier,
                applicationPath: applicationPath,
                tile: tile
            )
        }
    }

    private func readDockPlist() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: dockPlistURL.path) else {
            throw DockLayoutError.dockPlistMissing(dockPlistURL)
        }

        let data = try Data(contentsOf: dockPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw DockLayoutError.invalidDockPlist
        }

        return plist
    }

    private func makeTile(for slot: DockAppSlot, runningApp: RunningDockApp?) throws -> [String: Any] {
        let path = runningApp?.applicationPath ?? slot.applicationPath

        guard let path else {
            throw DockLayoutError.missingApplicationPath(slot)
        }

        let appURL = URL(fileURLWithPath: path, isDirectory: true)
        let runningLabel = runningApp?.label ?? ""
        let label = runningLabel.isEmpty ? slot.label : runningLabel

        return [
            "GUID": Int.random(in: 1...Int(UInt32.max)),
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": slot.bundleIdentifier,
                "dock-extra": false,
                "file-data": [
                    "_CFURLString": appURL.absoluteString,
                    "_CFURLStringType": 15
                ],
                "file-label": label,
                "file-type": 41
            ]
        ]
    }

    private func makeSpacerTile(size: DockEmptySlotSize) -> [String: Any] {
        [
            "tile-type": size.dockTileType
        ]
    }

    private func importDockPlist(_ plist: [String: Any]) throws {
        try ensureApplicationSupport()
        let tempURL = applicationSupportURL.appendingPathComponent("next-com.apple.dock.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: tempURL, options: .atomic)
        try runProcess("/usr/bin/defaults", arguments: ["import", dockDomain, tempURL.path])
    }

    private func restartDock(mode: DockRestartMode) throws {
        switch mode {
        case .normal:
            try runProcess("/usr/bin/killall", arguments: ["Dock"])
        case .fast:
            try runProcess("/usr/bin/killall", arguments: ["-KILL", "Dock"])
        }
    }

    private func ensureApplicationSupport() throws {
        try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
    }

    private func applicationPath(from tileData: [String: Any]) -> String? {
        guard let fileData = tileData["file-data"] as? [String: Any],
              let urlString = fileData["_CFURLString"] as? String else {
            return nil
        }

        if let url = URL(string: urlString), url.isFileURL {
            return url.path
        }

        if urlString.hasPrefix("/") {
            return urlString
        }

        return nil
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockLayoutError.processFailed(message?.isEmpty == false ? message! : "\(executable) failed.")
        }
    }
}
