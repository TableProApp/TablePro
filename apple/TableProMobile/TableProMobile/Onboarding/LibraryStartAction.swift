import Foundation

// One set of ways to fill an empty library, sent by the origin page and the empty list alike.
nonisolated enum LibraryStartAction: Hashable, Sendable {
    case turnOnICloud
    case importConnections
    case addConnection
    case openSample

    var title: LocalizedStringResource {
        switch self {
        case .turnOnICloud: "Turn On iCloud Sync"
        case .importConnections: "Import Connections"
        case .addConnection: "Add Connection"
        case .openSample: "Open Sample Database"
        }
    }

    var systemImage: String {
        switch self {
        case .turnOnICloud: "icloud"
        case .importConnections: "square.and.arrow.down"
        case .addConnection: "plus"
        case .openSample: "music.note.list"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .turnOnICloud: "turn-on-icloud"
        case .importConnections: "import-connections"
        case .addConnection: "add-connection"
        case .openSample: "open-sample"
        }
    }
}
