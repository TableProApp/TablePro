//
//  WelcomeRowPresentation.swift
//  TablePro
//

import AppKit
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
    internal let symbolName: String
    internal let connectionCount: Int
}

/// Shared by tags and groups, so each label carries its own symbol: a group draws the icon it was
/// given, a tag always draws the tag.
internal struct WelcomeTagLabel: Hashable {
    internal let name: String
    internal let color: ConnectionColor
    internal let symbolName: String
}

internal struct WelcomeConnectionRowModel: Equatable {
    internal let id: UUID
    internal let name: String
    internal let detail: String
    internal let type: DatabaseType
    internal let iconName: String?
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

    internal static func group(_ group: ConnectionGroup, connectionCount: Int) -> WelcomeGroupRowModel {
        WelcomeGroupRowModel(
            id: group.id,
            name: group.name,
            color: group.color,
            symbolName: LibraryGlyph.groupSymbol(group.iconName),
            connectionCount: connectionCount
        )
    }

    internal static func groupLabel(_ group: ConnectionGroup) -> WelcomeTagLabel {
        WelcomeTagLabel(name: group.name, color: group.color, symbolName: LibraryGlyph.groupSymbol(group.iconName))
    }

    internal static func tagLabel(_ tag: ConnectionTag) -> WelcomeTagLabel {
        WelcomeTagLabel(name: tag.name, color: tag.color, symbolName: "tag.fill")
    }

    internal static let renameGlyphSide: CGFloat = 16

    /// An image rather than a symbol name, because most engine logos are assets. An asset comes at
    /// its SVG artboard size (2500pt for one), and the rename field's image view is constrained in
    /// width only, so it would take that as its height.
    internal static func renameGlyph(for connection: DatabaseConnection) -> NSImage? {
        guard let image = LibraryGlyph.connectionNSImage(
            type: connection.type,
            iconName: connection.iconName,
            accessibilityDescription: nil
        ) else { return nil }
        let side = max(image.size.width, image.size.height)
        guard side > renameGlyphSide else { return image }
        let scale = renameGlyphSide / side
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return image
    }

    internal static func renameGlyph(for group: ConnectionGroup?) -> NSImage? {
        NSImage(systemSymbolName: LibraryGlyph.groupSymbol(group?.iconName), accessibilityDescription: nil)
    }

    internal static func savedConnection(
        _ connection: DatabaseConnection,
        section: LibrarySectionKind,
        tags: [ConnectionTag],
        group: ConnectionGroup?,
        groupPath: [String],
        isDriverRejected: Bool
    ) -> WelcomeConnectionRowModel {
        let labels = tags.map { tagLabel($0) }
        return WelcomeConnectionRowModel(
            id: connection.id,
            name: connection.name,
            detail: connection.connectionSubtitle,
            type: connection.type,
            iconName: connection.iconName,
            identityColor: connection.identityColor,
            tags: Array(labels.prefix(visibleTagLimit)),
            hiddenTagCount: max(0, labels.count - visibleTagLimit),
            groupLabel: section == .connections ? nil : group.map { groupLabel($0) },
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
            iconName: LibrarySymbolCatalog.normalizedName(exportable.iconName),
            identityColor: exportable.color.flatMap { ConnectionColor(rawValue: $0) }.flatMap { $0.isDefault ? nil : $0 },
            tags: [],
            hiddenTagCount: 0,
            groupLabel: nil,
            isLocalOnly: false,
            isDriverRejected: false,
            tooltip: [exportable.name, type.displayName, account + detail].joined(separator: "\n")
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
        var lines = [connection.name, connection.type.displayName]
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
