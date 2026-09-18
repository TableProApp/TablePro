import Foundation

public struct SpannerDDLCatalog: Sendable {
    private let tables: [SpannerDDLObjectKey: String]
    private let views: [SpannerDDLObjectKey: String]
    private let indexes: [SpannerDDLIndexEntry]

    public init(statements: [String], dialect: SpannerDialect) {
        var tables: [SpannerDDLObjectKey: String] = [:]
        var views: [SpannerDDLObjectKey: String] = [:]
        var indexes: [SpannerDDLIndexEntry] = []
        for statement in statements {
            switch SpannerDDLHead.parse(statement, dialect: dialect) {
            case .table(let key):
                tables[key] = tables[key] ?? statement
            case .view(let key):
                views[key] = views[key] ?? statement
            case .index(let table):
                indexes.append(SpannerDDLIndexEntry(table: table, statement: statement))
            case nil:
                continue
            }
        }
        self.tables = tables
        self.views = views
        self.indexes = indexes
    }

    public func tableDDL(schema: String, name: String) -> String? {
        tables[SpannerDDLObjectKey(schema: schema, name: name)]
    }

    public func indexDDL(schema: String, table: String) -> [String] {
        let key = SpannerDDLObjectKey(schema: schema, name: table)
        return indexes.filter { $0.table == key }.map(\.statement)
    }

    public func viewDDL(schema: String, name: String) -> String? {
        views[SpannerDDLObjectKey(schema: schema, name: name)]
    }
}

internal struct SpannerDDLObjectKey: Hashable, Sendable {
    let schema: String
    let name: String

    init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }

    init?(path: [String], dialect: SpannerDialect) {
        guard let name = path.last else { return nil }
        self.name = name
        self.schema = path.count > 1 ? path[path.count - 2] : dialect.defaultSchema
    }
}

internal struct SpannerDDLIndexEntry: Sendable {
    let table: SpannerDDLObjectKey
    let statement: String
}

internal enum SpannerDDLHead: Equatable {
    case table(SpannerDDLObjectKey)
    case view(SpannerDDLObjectKey)
    case index(table: SpannerDDLObjectKey)

    private static let modifiers: Set<String> = ["OR", "REPLACE", "UNIQUE", "NULL_FILTERED", "SEARCH", "VECTOR"]

    static func parse(_ statement: String, dialect: SpannerDialect) -> SpannerDDLHead? {
        var cursor = SpannerSQLCursor(statement)
        guard nextKeyword(&cursor) == "CREATE" else { return nil }
        var keyword = nextKeyword(&cursor)
        while let modifier = keyword, modifiers.contains(modifier) {
            keyword = nextKeyword(&cursor)
        }
        switch keyword {
        case "TABLE":
            return objectPath(&cursor, dialect: dialect).map(SpannerDDLHead.table)
        case "VIEW":
            return objectPath(&cursor, dialect: dialect).map(SpannerDDLHead.view)
        case "INDEX":
            return indexHead(&cursor, dialect: dialect)
        default:
            return nil
        }
    }

    private static func indexHead(_ cursor: inout SpannerSQLCursor, dialect: SpannerDialect) -> SpannerDDLHead? {
        guard objectPath(&cursor, dialect: dialect) != nil, nextKeyword(&cursor) == "ON" else { return nil }
        return objectPath(&cursor, dialect: dialect).map { SpannerDDLHead.index(table: $0) }
    }

    private static func objectPath(_ cursor: inout SpannerSQLCursor, dialect: SpannerDialect) -> SpannerDDLObjectKey? {
        skipIfNotExists(&cursor)
        cursor.skipNoise(skippingHints: false)
        guard let path = cursor.readPath() else { return nil }
        return SpannerDDLObjectKey(path: path, dialect: dialect)
    }

    private static func skipIfNotExists(_ cursor: inout SpannerSQLCursor) {
        var lookahead = cursor
        guard nextKeyword(&lookahead) == "IF",
              nextKeyword(&lookahead) == "NOT",
              nextKeyword(&lookahead) == "EXISTS"
        else {
            return
        }
        cursor = lookahead
    }

    private static func nextKeyword(_ cursor: inout SpannerSQLCursor) -> String? {
        cursor.skipNoise(skippingHints: false)
        return cursor.readWord()?.uppercased()
    }
}
