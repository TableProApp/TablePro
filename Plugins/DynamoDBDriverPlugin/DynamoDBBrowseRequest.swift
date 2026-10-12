import Foundation
import TableProPluginKit

struct DynamoDBBrowseFilter: Sendable, Equatable {
    let attribute: String
    let op: String
    let value: String
    let secondValue: String?
    /// The grid's kind for the column (`text`, `integer`, `decimal`, `boolean`), a hint only.
    let kind: String?
    let caseSensitive: Bool
}

/// What a table tab asks for: the table, the grid's filters and its columns.
///
/// This is the request, not the plan. The driver picks the table, a local index or a global index
/// and the key condition when the statement runs, against the table as it is then, so the grid
/// never builds one page with an old key schema and the next with a new one.
struct DynamoDBBrowseRequest: Sendable, Equatable {
    let table: String
    let filters: [DynamoDBBrowseFilter]
    let matchAll: Bool
    let columns: [String]

    init(table: String, filters: [DynamoDBBrowseFilter], matchAll: Bool, columns: [String]) {
        self.table = table
        self.filters = filters
        self.matchAll = matchAll
        self.columns = columns
    }

    init(
        table: String,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        columns: [String],
        columnKinds: [String: PluginColumnKind]
    ) {
        self.table = table
        self.filters = queryFilters.map { filter in
            DynamoDBBrowseFilter(
                attribute: filter.column,
                op: filter.op.uppercased(),
                value: filter.value,
                secondValue: filter.secondValue,
                kind: columnKinds[filter.column]?.rawValue,
                caseSensitive: filter.isCaseSensitive
            )
        }
        self.matchAll = logicMode.lowercased() != "or"
        self.columns = columns
    }

    init(json: DynamoDBJSON) throws {
        guard let table = json["TableName"]?.stringValue, !table.isEmpty else {
            throw DynamoDBError.invalidStatement(String(localized: "Browse needs a TableName"))
        }
        self.table = table
        self.filters = try (json["Filters"]?.arrayValue ?? []).map { entry in
            guard let attribute = entry["Attribute"]?.stringValue, let op = entry["Operator"]?.stringValue else {
                throw DynamoDBError.invalidStatement(String(localized: "Each Browse filter needs an Attribute and an Operator"))
            }
            return DynamoDBBrowseFilter(
                attribute: attribute,
                op: op.uppercased(),
                value: Self.text(entry["Value"]) ?? "",
                secondValue: Self.text(entry["SecondValue"]),
                kind: entry["Kind"]?.stringValue,
                caseSensitive: entry["CaseSensitive"]?.boolValue ?? true
            )
        }
        self.matchAll = json["Match"]?.stringValue?.lowercased() != "any"
        self.columns = (json["Columns"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    private static func text(_ json: DynamoDBJSON?) -> String? {
        switch json {
        case .string(let value)?: return value
        case .number(let value)?: return value
        case .bool(let value)?: return value ? "true" : "false"
        default: return nil
        }
    }

    var json: DynamoDBJSON {
        var object: [String: DynamoDBJSON] = ["TableName": .string(table)]
        if !filters.isEmpty {
            object["Filters"] = .array(filters.map { filter in
                var entry: [String: DynamoDBJSON] = [
                    "Attribute": .string(filter.attribute),
                    "Operator": .string(filter.op),
                    "Value": .string(filter.value)
                ]
                if let second = filter.secondValue { entry["SecondValue"] = .string(second) }
                if let kind = filter.kind { entry["Kind"] = .string(kind) }
                if !filter.caseSensitive { entry["CaseSensitive"] = .bool(false) }
                return .object(entry)
            })
            object["Match"] = .string(matchAll ? "All" : "Any")
        }
        if !columns.isEmpty {
            object["Columns"] = .array(columns.map(DynamoDBJSON.string))
        }
        return .object(object)
    }
}
