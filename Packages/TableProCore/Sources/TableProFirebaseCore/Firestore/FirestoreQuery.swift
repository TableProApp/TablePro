import Foundation

public struct FirebaseFilterSpec: Codable, Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?

    public init(column: String, op: String, value: String, secondValue: String? = nil) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }

    /// The host sends BETWEEN as `value: "lower,upper"` with the upper bound again in `secondValue`,
    /// so the lower bound is `value` without that suffix, whatever commas the bounds hold.
    public var betweenBounds: (lower: String, upper: String)? {
        guard let upper = secondValue else {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let suffix = Array(("," + upper).unicodeScalars)
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= suffix.count, Array(scalars.suffix(suffix.count)) == suffix else {
            return (value, upper)
        }
        var lower = String.UnicodeScalarView()
        lower.append(contentsOf: scalars.dropLast(suffix.count))
        return (String(lower), upper)
    }
}

public struct FirebaseSortSpec: Codable, Sendable, Equatable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// Turned into a query only when it runs, because filter values are typed by the fields the
/// collection was last seen holding.
public struct FirebaseBrowseSpec: Codable, Sendable, Equatable {
    public let table: String
    public let filters: [FirebaseFilterSpec]
    public let logicMode: String
    public let sorts: [FirebaseSortSpec]
    public let limit: Int
    public let offset: Int

    public init(
        table: String,
        filters: [FirebaseFilterSpec] = [],
        logicMode: String = "AND",
        sorts: [FirebaseSortSpec] = [],
        limit: Int,
        offset: Int
    ) {
        self.table = table
        self.filters = filters
        self.logicMode = logicMode
        self.sorts = sorts
        self.limit = limit
        self.offset = offset
    }

    public var usesOr: Bool {
        logicMode.uppercased() == "OR"
    }
}

/// A table in the sidebar is either a collection path (`users`, `users/alice/orders`) or a
/// collection group, `*/orders`, which is every `orders` collection at any depth.
public struct FirestoreCollectionTarget: Sendable, Equatable {
    public static let groupPrefix = "*/"

    public let parentPath: String
    public let collectionId: String
    public let isGroup: Bool

    public init(table: String) throws {
        let trimmed = table.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.hasPrefix(Self.groupPrefix) {
            let id = String(trimmed.dropFirst(Self.groupPrefix.count))
            guard !id.isEmpty, !id.contains("/") else { throw Self.invalid(table) }
            self.parentPath = ""
            self.collectionId = id
            self.isGroup = true
            return
        }
        guard !trimmed.isEmpty, !FirestorePath.isDocument(trimmed) else { throw Self.invalid(table) }
        let split = FirestorePath.split(collectionPath: trimmed)
        self.parentPath = split.parent
        self.collectionId = split.collectionId
        self.isGroup = false
    }

    public var collectionPath: String {
        parentPath.isEmpty ? collectionId : parentPath + "/" + collectionId
    }

    public static func groupName(_ collectionId: String) -> String {
        groupPrefix + collectionId
    }

    /// The `__name__` cell of a row: the document ID in a collection, the whole path in a group,
    /// where IDs repeat across parents.
    public func rowName(forDocumentPath path: String) -> String {
        isGroup ? path : FirestorePath.lastSegment(path)
    }

    public func documentPath(forRowName name: String) -> String {
        if isGroup || name.contains("/") {
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return collectionPath + "/" + name
    }

    private static func invalid(_ table: String) -> FirebaseError {
        .configuration(String(format: String(localized: "\"%@\" is not a collection path."), table))
    }
}

public enum FirestoreQueryBuilder {
    public static let nameField = "__name__"
    static let unsupportedOperator = String(
        localized: "Firestore cannot filter with %@. It supports =, !=, <, <=, >, >=, IN, NOT IN, BETWEEN, STARTS WITH, IS NULL, and CONTAINS on an array field."
    )
    public static let rawFilterColumn = "__RAW__"
    /// Kept out of the localized key, so a translator never edits JSON and a test can run it.
    static let rawFilterExample = #"{"unaryFilter": {"field": {"fieldPath": "email"}, "op": "IS_NULL"}}"#

    /// `typeOf` answers the type a field was last seen holding, so `zip = 30` compares against the
    /// string "30" when zip is a string field.
    public static func structuredQuery(
        spec: FirebaseBrowseSpec,
        target: FirestoreCollectionTarget,
        documentRoot: String,
        typeOf: (String) -> String?
    ) throws -> FirebaseJSON {
        var query = try baseQuery(spec: spec, target: target, documentRoot: documentRoot, typeOf: typeOf)
        if spec.offset > 0 { query["offset"] = .int(Int64(spec.offset)) }
        if spec.limit > 0 { query["limit"] = .int(Int64(spec.limit)) }
        return .object(["structuredQuery": .object(query)])
    }

    /// Keeps the order because ordering by a field drops the documents without it, and the count
    /// has to match the rows the grid shows.
    public static func countQuery(
        spec: FirebaseBrowseSpec,
        target: FirestoreCollectionTarget,
        documentRoot: String,
        typeOf: (String) -> String?
    ) throws -> FirebaseJSON {
        let query = try baseQuery(spec: spec, target: target, documentRoot: documentRoot, typeOf: typeOf)
        return .object(["structuredAggregationQuery": .object([
            "structuredQuery": .object(query),
            "aggregations": .array([.object(["alias": .string("total"), "count": .object([:])])])
        ])])
    }

    private static func baseQuery(
        spec: FirebaseBrowseSpec,
        target: FirestoreCollectionTarget,
        documentRoot: String,
        typeOf: (String) -> String?
    ) throws -> [String: FirebaseJSON] {
        var query: [String: FirebaseJSON] = [
            "from": .array([.object([
                "collectionId": .string(target.collectionId),
                "allDescendants": .bool(target.isGroup)
            ])])
        ]
        let filters = try spec.filters.map { filter in
            try self.filter(filter, target: target, documentRoot: documentRoot, typeOf: typeOf)
        }
        if let combined = combine(filters, op: spec.usesOr ? "OR" : "AND") {
            query["where"] = combined
        }
        if !spec.sorts.isEmpty {
            query["orderBy"] = .array(spec.sorts.map { sort in
                .object([
                    "field": .object(["fieldPath": .string(fieldPath(sort.column))]),
                    "direction": .string(sort.ascending ? "ASCENDING" : "DESCENDING")
                ])
            })
        }
        return query
    }

    public static func sortedFields(_ spec: FirebaseBrowseSpec) -> [String] {
        spec.sorts.map(\.column).filter { $0 != nameField }
    }

    static func combine(_ filters: [FirebaseJSON], op: String) -> FirebaseJSON? {
        switch filters.count {
        case 0: return nil
        case 1: return filters[0]
        default:
            return .object(["compositeFilter": .object(["op": .string(op), "filters": .array(filters)])])
        }
    }

    static func filter(
        _ filter: FirebaseFilterSpec,
        target: FirestoreCollectionTarget,
        documentRoot: String,
        typeOf: (String) -> String?
    ) throws -> FirebaseJSON {
        if filter.column == rawFilterColumn {
            return try rawFilter(filter.value)
        }
        let path = fieldPath(filter.column)
        let columnType = typeOf(filter.column)
        let typed: (String) throws -> FirebaseJSON = { text in
            try operand(text, column: filter.column, typeName: columnType, target: target, documentRoot: documentRoot)
        }
        switch filter.op.uppercased() {
        case "=":
            return field(path, "EQUAL", try typed(filter.value))
        case "!=", "<>":
            return field(path, "NOT_EQUAL", try typed(filter.value))
        case ">":
            return field(path, "GREATER_THAN", try typed(filter.value))
        case ">=":
            return field(path, "GREATER_THAN_OR_EQUAL", try typed(filter.value))
        case "<":
            return field(path, "LESS_THAN", try typed(filter.value))
        case "<=":
            return field(path, "LESS_THAN_OR_EQUAL", try typed(filter.value))
        case "IN", "NOT IN":
            let items = try listItems(filter.value).map(typed)
            guard !items.isEmpty, items.count <= 30 else {
                throw FirebaseError.unsupported(String(localized: "Firestore compares IN and NOT IN against 1 to 30 values."))
            }
            let op = filter.op.uppercased() == "IN" ? "IN" : "NOT_IN"
            return field(path, op, .object(["arrayValue": .object(["values": .array(items)])]))
        case "BETWEEN":
            guard let bounds = filter.betweenBounds else {
                throw FirebaseError.configuration(String(localized: "BETWEEN needs two values."))
            }
            return .object(["compositeFilter": .object(["op": .string("AND"), "filters": .array([
                field(path, "GREATER_THAN_OR_EQUAL", try typed(bounds.lower)),
                field(path, "LESS_THAN_OR_EQUAL", try typed(bounds.upper))
            ])])])
        case "STARTS WITH":
            return .object(["compositeFilter": .object(["op": .string("AND"), "filters": .array([
                field(path, "GREATER_THAN_OR_EQUAL", .object(["stringValue": .string(filter.value)])),
                field(path, "LESS_THAN", .object(["stringValue": .string(filter.value + "\u{F8FF}")]))
            ])])])
        case "CONTAINS" where columnType == FirestoreTypeName.array:
            let element = FirestoreCell.inferred(filter.value).rest(documentRoot: documentRoot)
            return field(path, "ARRAY_CONTAINS", element)
        case "IS NULL":
            return unary(path, "IS_NULL")
        case "IS NOT NULL":
            return unary(path, "IS_NOT_NULL")
        default:
            throw FirebaseError.unsupported(String(format: unsupportedOperator, filter.op))
        }
    }

    /// Field names outside `[A-Za-z_][A-Za-z0-9_]*` go in backticks, the way the API spells them.
    public static func fieldPath(_ column: String) -> String {
        if column == nameField { return column }
        let simple = column.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        if simple { return column }
        let escaped = column.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        return "`" + escaped + "`"
    }

    /// An update mask as a request line carries it: top-level field names, comma separated, each
    /// in backticks when it holds anything but letters, digits and `_`.
    public static func maskText(_ fields: [String]) -> String {
        fields.map(fieldPath).joined(separator: ",")
    }

    public static func maskFields(_ text: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var escaping = false
        var wasQuoted = false
        func finish() {
            let name = wasQuoted ? current : current.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { fields.append(name) }
            current = ""
            wasQuoted = false
        }
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
            } else if quoted {
                switch character {
                case "\\": escaping = true
                case "`": quoted = false
                default: current.append(character)
                }
            } else {
                switch character {
                case "`":
                    quoted = true
                    wasQuoted = true
                    current = ""
                case ",":
                    finish()
                default:
                    current.append(character)
                }
            }
        }
        finish()
        return fields
    }

    private static func operand(
        _ text: String,
        column: String,
        typeName: String?,
        target: FirestoreCollectionTarget,
        documentRoot: String
    ) throws -> FirebaseJSON {
        if column == nameField {
            let path = target.documentPath(forRowName: text)
            return .object(["referenceValue": .string(FirestorePath.absolute(path, documentRoot: documentRoot))])
        }
        return try FirestoreCell.value(text: text, typeName: typeName).rest(documentRoot: documentRoot)
    }

    private static func field(_ path: String, _ op: String, _ value: FirebaseJSON) -> FirebaseJSON {
        .object(["fieldFilter": .object([
            "field": .object(["fieldPath": .string(path)]),
            "op": .string(op),
            "value": value
        ])])
    }

    private static func unary(_ path: String, _ op: String) -> FirebaseJSON {
        .object(["unaryFilter": .object([
            "field": .object(["fieldPath": .string(path)]),
            "op": .string(op)
        ])])
    }

    /// The raw filter row takes a REST `Filter` object as written in the Firestore API reference,
    /// which is the only way to reach a nested field or a composite the filter bar cannot draw.
    private static func rawFilter(_ text: String) throws -> FirebaseJSON {
        let refusal = FirebaseError.configuration(
            String(format: String(localized: "A raw Firestore filter is a JSON Filter object, such as %@."), rawFilterExample)
        )
        guard let json = try? FirebaseJSON.parse(text), let members = json.objectValue, members.count == 1,
              let key = members.keys.first, ["fieldFilter", "unaryFilter", "compositeFilter"].contains(key) else {
            throw refusal
        }
        return json
    }

    static func listItems(_ text: String) -> [String] {
        if let json = try? FirebaseJSON.parse(text), case .array(let values) = json {
            return values.map { value in value.stringValue ?? value.text() }
        }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
