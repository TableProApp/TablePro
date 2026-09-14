//
//  WelcomeRowPresentation.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProImport

internal enum WelcomeRowModel: Equatable {
    case section(title: String)
    case group(WelcomeGroupRowModel)
    case connection(WelcomeConnectionRowModel)
    case empty
}

internal struct WelcomeGroupRowModel: Equatable {
    internal let id: UUID
    internal let name: String
    internal let color: ConnectionColor
    internal let connectionCount: Int
}

internal struct WelcomeTagLabel: Hashable {
    internal let name: String
    internal let color: ConnectionColor
}

internal struct WelcomeConnectionRowModel: Equatable {
    internal let id: UUID
    internal let name: String
    internal let detail: String
    internal let type: DatabaseType
    internal let identityColor: ConnectionColor?
    internal let tags: [WelcomeTagLabel]
    internal let hiddenTagCount: Int
    internal let groupLabel: WelcomeTagLabel?
    internal let isLocalOnly: Bool
    internal let isDriverRejected: Bool
    internal let tooltip: String
}

internal enum WelcomeSortOption: CaseIterable {
    case manual
    case name
    case databaseType
    case lastConnected

    internal var mode: LibrarySortMode {
        switch self {
        case .manual: return .manual
        case .name: return .name
        case .databaseType: return .databaseType
        case .lastConnected: return .lastConnected
        }
    }

    internal var title: String {
        switch self {
        case .manual: return String(localized: "Manual")
        case .name: return String(localized: "Name")
        case .databaseType: return String(localized: "Database Type")
        case .lastConnected: return String(localized: "Last Connected")
        }
    }
}

@MainActor
internal enum WelcomeRowPresentation {
    internal static let visibleTagLimit = 2

    internal static func title(for kind: LibrarySectionKind) -> String {
        switch kind {
        case .favorites: return String(localized: "Favorites")
        case .recent: return String(localized: "Recent")
        case .connections: return String(localized: "Connections")
        case .linkedFolders: return String(localized: "Linked Folders")
        case .teamLibrary: return String(localized: "Team Library")
        }
    }

    internal static func savedConnection(
        _ connection: DatabaseConnection,
        section: LibrarySectionKind,
        tags: [ConnectionTag],
        group: ConnectionGroup?,
        groupPath: [String],
        isDriverRejected: Bool
    ) -> WelcomeConnectionRowModel {
        let labels = tags.map { WelcomeTagLabel(name: $0.name, color: $0.color) }
        return WelcomeConnectionRowModel(
            id: connection.id,
            name: connection.name,
            detail: connection.connectionSubtitle,
            type: connection.type,
            identityColor: connection.identityColor,
            tags: Array(labels.prefix(visibleTagLimit)),
            hiddenTagCount: max(0, labels.count - visibleTagLimit),
            groupLabel: section == .connections ? nil : group.map { WelcomeTagLabel(name: $0.name, color: $0.color) },
            isLocalOnly: connection.localOnly && !connection.isSample,
            isDriverRejected: isDriverRejected,
            tooltip: tooltip(for: connection, groupPath: groupPath, tags: tags)
        )
    }

    internal static func sharedConnection(_ linked: LinkedConnection, section: LibrarySectionKind) -> WelcomeConnectionRowModel {
        let exportable = linked.connection
        let type = DatabaseType(rawValue: exportable.type)
        let detail = endpoint(
            host: exportable.host,
            port: exportable.port,
            defaultPort: type.defaultPort,
            database: exportable.database
        )
        let account = exportable.username.isEmpty ? "" : exportable.username + "@"
        return WelcomeConnectionRowModel(
            id: linked.id,
            name: exportable.name,
            detail: detail,
            type: type,
            identityColor: exportable.color.flatMap { ConnectionColor(rawValue: $0) }.flatMap { $0.isDefault ? nil : $0 },
            tags: [],
            hiddenTagCount: 0,
            groupLabel: nil,
            isLocalOnly: false,
            isDriverRejected: false,
            tooltip: [exportable.name, account + detail].joined(separator: "\n")
        )
    }

    internal static func endpoint(host: String, port: Int, defaultPort: Int, database: String) -> String {
        guard !host.isEmpty else { return database }
        var endpoint = host
        if port > 0, port != defaultPort {
            endpoint += ":\(port)"
        }
        if !database.isEmpty {
            endpoint += "/" + database
        }
        return endpoint
    }

    internal static func tooltip(for connection: DatabaseConnection, groupPath: [String], tags: [ConnectionTag]) -> String {
        var lines = [connection.name]
        let account = connection.username.isEmpty ? "" : connection.username + "@"
        lines.append(account + connection.connectionSubtitle)
        if !groupPath.isEmpty {
            lines.append(String(format: String(localized: "Group: %@"), groupPath.joined(separator: " / ")))
        }
        if !tags.isEmpty {
            lines.append(String(format: String(localized: "Tags: %@"), tags.map(\.name).joined(separator: ", ")))
        }
        if connection.localOnly && !connection.isSample {
            lines.append(String(localized: "Not synced to iCloud"))
        }
        return lines.joined(separator: "\n")
    }
}
