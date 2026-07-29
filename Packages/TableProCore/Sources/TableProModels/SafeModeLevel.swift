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
        case .off: return "Off"
        case .confirmWrites: return "Confirm Writes"
        case .readOnly: return "Read-Only"
        }
    }
}
