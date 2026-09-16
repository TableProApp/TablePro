import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated struct ConnectionListLabel: Hashable, Sendable {
    let name: String
    let color: ConnectionColor
}

nonisolated struct ConnectionListRowModel: Hashable, Sendable {
    static let visibleTagLimit = 2

    let id: UUID
    let title: String
    let detail: String
    let type: DatabaseType
    let color: ConnectionColor
    let tags: [ConnectionListLabel]
    let hiddenTagCount: Int
    let tagNames: [String]
    let groupLabel: ConnectionListLabel?
    let isFavorite: Bool
    let showsFavoriteMark: Bool

    init(
        connection: DatabaseConnection,
        section: LibrarySectionKind,
        tags allTags: [ConnectionTag],
        groups: [ConnectionGroup]
    ) {
        id = connection.id
        title = connection.name.isEmpty ? connection.host : connection.name
        detail = ConnectionDetailFormatter.detail(for: connection)
        type = connection.type
        color = connection.color
        isFavorite = connection.isFavorite
        showsFavoriteMark = connection.isFavorite && section == .connections

        let tagsById = Dictionary(allTags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = connection.tagIds.compactMap { tagsById[$0] }
        tags = resolved.prefix(Self.visibleTagLimit).map { ConnectionListLabel(name: $0.name, color: $0.color) }
        hiddenTagCount = max(0, resolved.count - Self.visibleTagLimit)
        tagNames = resolved.map(\.name)

        let showsGroup = section == .favorites || section == .recent
        let group = connection.groupId.flatMap { id in groups.first { $0.id == id } }
        groupLabel = showsGroup ? group.map { ConnectionListLabel(name: $0.name, color: $0.color) } : nil
    }

    var accessibilityLabel: String {
        var parts = [title, type.mobileDisplayName, detail]
        if let groupLabel {
            parts.append(String(format: String(localized: "in %@"), groupLabel.name))
        }
        if !tagNames.isEmpty {
            parts.append(String(format: String(localized: "tags %@"), tagNames.joined(separator: ", ")))
        }
        if isFavorite {
            parts.append(String(localized: "Favorite"))
        }
        return parts.joined(separator: ", ")
    }
}
