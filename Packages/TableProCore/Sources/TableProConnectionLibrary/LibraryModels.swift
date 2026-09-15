import Foundation

public protocol LibraryConnectionRepresentable {
    var id: UUID { get }
    var name: String { get }
    var host: String { get }
    var database: String { get }
    var username: String { get }
    var libraryTypeName: String { get }
    var groupId: UUID? { get }
    var tagIds: [UUID] { get }
    var sortOrder: Int { get }
    var isFavorite: Bool { get }
}

public protocol LibraryGroupRepresentable {
    var id: UUID { get }
    var name: String { get }
    var parentId: UUID? { get }
    var sortOrder: Int { get }
}

public protocol LibraryTagRepresentable {
    var id: UUID { get }
    var name: String { get }
}

public enum LibrarySortMode: String, Codable, CaseIterable, Sendable {
    case manual
    case name
    case databaseType
    case lastConnected
}

public enum LibraryTagMatch: String, Codable, CaseIterable, Sendable {
    case any
    case all
}

public struct LibraryQuery: Hashable, Sendable {
    public var text: String
    public var tagIds: Set<UUID>
    public var tagMatch: LibraryTagMatch

    public init(text: String = "", tagIds: Set<UUID> = [], tagMatch: LibraryTagMatch = .any) {
        self.text = text
        self.tagIds = tagIds
        self.tagMatch = tagMatch
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isActive: Bool {
        !trimmedText.isEmpty || !tagIds.isEmpty
    }

    public var hasTextTerm: Bool {
        !trimmedText.isEmpty
    }
}

public enum LibrarySectionKind: String, Codable, CaseIterable, Sendable {
    case favorites
    case recent
    case connections
    case linkedFolders
    case teamLibrary

    public var acceptsSavedConnections: Bool {
        switch self {
        case .favorites, .recent, .connections:
            return true
        case .linkedFolders, .teamLibrary:
            return false
        }
    }
}

public enum LibraryRowID: Hashable, Sendable {
    case section(LibrarySectionKind)
    case group(UUID)
    case connection(UUID, section: LibrarySectionKind)
}

public indirect enum LibraryNode: Hashable, Sendable {
    case group(id: UUID, children: [LibraryNode], connectionCount: Int)
    case connection(id: UUID)

    public func rowID(in section: LibrarySectionKind) -> LibraryRowID {
        switch self {
        case .group(let id, _, _):
            return .group(id)
        case .connection(let id):
            return .connection(id, section: section)
        }
    }

    public var children: [LibraryNode] {
        switch self {
        case .group(_, let children, _):
            return children
        case .connection:
            return []
        }
    }

    public var connectionCount: Int {
        switch self {
        case .group(_, _, let count):
            return count
        case .connection:
            return 1
        }
    }
}

public struct LibrarySection: Hashable, Sendable {
    public let kind: LibrarySectionKind
    public let nodes: [LibraryNode]

    public init(kind: LibrarySectionKind, nodes: [LibraryNode]) {
        self.kind = kind
        self.nodes = nodes
    }
}

public struct LibraryOutline: Hashable, Sendable {
    public let sections: [LibrarySection]
    public let groupIdsExpandedByQuery: Set<UUID>
    public let isQueryActive: Bool

    public init(sections: [LibrarySection], groupIdsExpandedByQuery: Set<UUID>, isQueryActive: Bool) {
        self.sections = sections
        self.groupIdsExpandedByQuery = groupIdsExpandedByQuery
        self.isQueryActive = isQueryActive
    }

    public static let empty = LibraryOutline(sections: [], groupIdsExpandedByQuery: [], isQueryActive: false)

    public func section(_ kind: LibrarySectionKind) -> LibrarySection? {
        sections.first { $0.kind == kind }
    }

    public var isEmpty: Bool {
        sections.allSatisfy { $0.nodes.isEmpty }
    }

    public func connectionIds(in kind: LibrarySectionKind) -> [UUID] {
        guard let section = section(kind) else { return [] }
        return Self.connectionIds(in: section.nodes)
    }

    public var connectionIdsInDisplayOrder: [UUID] {
        var seen: Set<UUID> = []
        return sections
            .flatMap { Self.connectionIds(in: $0.nodes) }
            .filter { seen.insert($0).inserted }
    }

    private static func connectionIds(in nodes: [LibraryNode]) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            switch node {
            case .connection(let id):
                return [id]
            case .group(_, let children, _):
                return connectionIds(in: children)
            }
        }
    }
}

public struct LibraryExternalEntry: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let host: String
    public let database: String
    public let username: String
    public let typeName: String

    public init(id: UUID, name: String, host: String, database: String, username: String, typeName: String) {
        self.id = id
        self.name = name
        self.host = host
        self.database = database
        self.username = username
        self.typeName = typeName
    }
}

public struct LibraryExternalSection: Hashable, Sendable {
    public let kind: LibrarySectionKind
    public let entries: [LibraryExternalEntry]

    public init(kind: LibrarySectionKind, entries: [LibraryExternalEntry]) {
        self.kind = kind
        self.entries = entries
    }
}
