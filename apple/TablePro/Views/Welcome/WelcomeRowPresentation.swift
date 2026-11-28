//
//  WelcomeRowPresentation.swift
//  TablePro
//

import AppKit
import TableProConnectionLibrary
import TableProImport

internal enum WelcomeRowModel: Equatable {
    case section(title: String)
    case teamLibrarySection(title: String)
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

// Shared by tags and groups: a group draws the icon it was given, a tag always draws the tag.
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
    internal let environment: ConnectionEnvironment
    internal let tags: [WelcomeTagLabel]
    internal let hiddenTagCount: Int
    internal let groupLabel: WelcomeTagLabel?
    internal let isLocalOnly: Bool
    internal let isDriverRejected: Bool
    internal let tooltip: String
    // Part of the model so a reload hands a reused row a changed value; status has no observable home.
    internal let status: ConnectionDisplayStatus

    internal var hasSecondLine: Bool {
        !detail.isEmpty || groupLabel != nil || !tags.isEmpty || hiddenTagCount > 0
    }

    // The tile is hidden from VoiceOver, so the label names the engine a custom icon may replace.
    internal var accessibilityLabel: String {
        [name, type.displayName, environment.accessibilityName]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    internal var accessibilityValue: String {
        let presentation = ConnectionStatusPresentation(status)
        var parts: [String] = []
        if isDriverRejected { parts.append(String(localized: "Plugin not loaded")) }
        if isLocalOnly { parts.append(String(localized: "Local only")) }
        if presentation.symbol != nil { parts.append(presentation.accessibilityStatus) }
        parts.append(detail)
        if let groupLabel { parts.append(groupLabel.name) }
        parts.append(contentsOf: tags.map(\.name))
        if hiddenTagCount > 0 { parts.append(String(format: String(localized: "+%lld"), Int64(hiddenTagCount))) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
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

    // An asset logo comes at its artboard size, which the width-only rename image view takes as its height.
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
            detail: Self.detail(connection.connectionSubtitle, under: connection.name),
            type: connection.type,
            iconName: connection.iconName,
            identityColor: connection.identityColor,
            environment: ConnectionEnvironment.stored(in: connection.additionalFields),
            tags: Array(labels.prefix(visibleTagLimit)),
            hiddenTagCount: max(0, labels.count - visibleTagLimit),
            groupLabel: section == .connections ? nil : group.map { groupLabel($0) },
            isLocalOnly: connection.localOnly && !connection.isSample,
            isDriverRejected: isDriverRejected,
            tooltip: tooltip(for: connection, groupPath: groupPath, tags: tags),
            status: ConnectionStatusResolver.status(for: connection.id)
        )
    }

    // A team's copy says in its tooltip who last changed it, as the core reports for the item.
    internal static func teamConnection(
        _ connection: DatabaseConnection,
        section: LibrarySectionKind,
        lastWriter: String?,
        lastChangedAt: Date?
    ) -> WelcomeConnectionRowModel {
        let row = savedConnection(connection, section: section, tags: [], group: nil, groupPath: [], isDriverRejected: false)
        guard let lastChange = lastChangeLine(by: lastWriter, at: lastChangedAt) else { return row }
        return WelcomeConnectionRowModel(
            id: row.id,
            name: row.name,
            detail: row.detail,
            type: row.type,
            iconName: row.iconName,
            identityColor: row.identityColor,
            environment: row.environment,
            tags: row.tags,
            hiddenTagCount: row.hiddenTagCount,
            groupLabel: row.groupLabel,
            isLocalOnly: row.isLocalOnly,
            isDriverRejected: row.isDriverRejected,
            tooltip: row.tooltip + "\n" + lastChange,
            status: row.status
        )
    }

    // Nil when the pull named no one to this account.
    internal static func lastChangeLine(by writer: String?, at date: Date?) -> String? {
        guard let writer else { return nil }
        guard let date else { return String(format: String(localized: "Last changed by %@"), writer) }
        return String(
            format: String(localized: "Last changed by %1$@ on %2$@"),
            writer,
            date.formatted(date: .abbreviated, time: .shortened)
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
            detail: Self.detail(detail, under: exportable.name),
            type: type,
            iconName: LibrarySymbolCatalog.normalizedName(exportable.iconName),
            identityColor: exportable.color.flatMap { ConnectionColor(rawValue: $0) }.flatMap { $0.isDefault ? nil : $0 },
            environment: ConnectionEnvironment.stored(in: exportable.additionalFields),
            tags: [],
            hiddenTagCount: 0,
            groupLabel: nil,
            isLocalOnly: false,
            isDriverRejected: false,
            tooltip: [exportable.name, type.displayName, account + detail].joined(separator: "\n"),
            status: ConnectionStatusResolver.status(for: linked.id)
        )
    }

    // A connection saved with no name is named after its address, which would then repeat under it.
    internal static func detail(_ detail: String, under name: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        return trimmed == name.trimmingCharacters(in: .whitespaces) ? "" : detail
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
