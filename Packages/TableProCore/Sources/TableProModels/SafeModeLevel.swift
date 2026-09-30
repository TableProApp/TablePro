import Foundation

public enum WritePermission: Sendable {
    case proceed
    case requiresConfirmation
    case blocked
}

public enum SafeModeLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case off = "off"
    case confirmWrites = "confirmWrites"
    case readOnly = "readOnly"

    public init(wireValue: String?, isReadOnly: Bool) {
        guard let wireValue else {
            self = isReadOnly ? .readOnly : .off
            return
        }
        if let level = SafeModeLevel(rawValue: wireValue) {
            self = level
            return
        }
        switch wireValue {
        case "silent": self = .off
        case "alert", "alertFull", "safeMode", "safeModeFull": self = .confirmWrites
        default: self = isReadOnly ? .readOnly : .confirmWrites
        }
    }

    public var id: String { rawValue }

    public var blocksWrites: Bool { self == .readOnly }

    public var requiresConfirmation: Bool { self == .confirmWrites }

    public var writePermission: WritePermission {
        if blocksWrites { return .blocked }
        if requiresConfirmation { return .requiresConfirmation }
        return .proceed
    }

    public var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .confirmWrites: return String(localized: "Confirm Writes")
        case .readOnly: return String(localized: "Read-Only")
        }
    }
}
