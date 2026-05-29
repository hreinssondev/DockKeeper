import Foundation

enum DockEmptySlotSize: String, Codable, CaseIterable, Identifiable {
    case full
    case half

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full:
            "Full"
        case .half:
            "Half"
        }
    }

    var dockTileType: String {
        switch self {
        case .full:
            "spacer-tile"
        case .half:
            "small-spacer-tile"
        }
    }
}

struct DockAppSlot: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var bundleIdentifier: String
    var applicationPath: String?
    var isPermanent: Bool
    var reservesEmptySlot: Bool
    var reservedEmptySlotSize: DockEmptySlotSize

    init(
        id: UUID = UUID(),
        label: String,
        bundleIdentifier: String,
        applicationPath: String?,
        isPermanent: Bool = false,
        reservesEmptySlot: Bool = false,
        reservedEmptySlotSize: DockEmptySlotSize = .full
    ) {
        self.id = id
        self.label = label
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.isPermanent = isPermanent
        self.reservesEmptySlot = reservesEmptySlot
        self.reservedEmptySlotSize = reservedEmptySlotSize
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case bundleIdentifier
        case applicationPath
        case isPermanent
        case reservesEmptySlot
        case reservedEmptySlotSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath)
        isPermanent = try container.decodeIfPresent(Bool.self, forKey: .isPermanent) ?? false
        reservesEmptySlot = try container.decodeIfPresent(Bool.self, forKey: .reservesEmptySlot) ?? false
        reservedEmptySlotSize = try container.decodeIfPresent(DockEmptySlotSize.self, forKey: .reservedEmptySlotSize) ?? .full
    }
}

struct RunningDockApp: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let label: String
    let bundleIdentifier: String
    let applicationPath: String?
}
