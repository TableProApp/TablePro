import Foundation

enum MCPFilterArguments {
    static let operatorNames: [String] = FilterOperator.allCases.map(\.rawValue)

    static let filterSchema: JsonValue = MCPToolSchema.object(
        properties: [
            "column": MCPToolSchema.string(String(localized: "Column to filter on")),
            "operator": MCPToolSchema.string(
                String(localized: "Comparison operator"),
                enumValues: operatorNames
            ),
            "value": MCPToolSchema.string(String(localized: "Value the operator compares against")),
            "second_value": MCPToolSchema.string(String(localized: "Upper bound, for BETWEEN")),
            "case_sensitive": MCPToolSchema.boolean(String(localized: "Match case exactly"))
        ],
        required: ["column", "operator"]
    )

    static let sortSchema: JsonValue = MCPToolSchema.object(
        properties: [
            "column": MCPToolSchema.string(String(localized: "Column to sort on")),
            "direction": MCPToolSchema.string(
                String(localized: "Sort direction (default ascending)"),
                enumValues: ["ascending", "descending"]
            )
        ],
        required: ["column"]
    )

    static func filters(_ arguments: JsonValue, key: String = "filters") throws -> [TableFilter] {
        guard let objects = try MCPArgumentDecoder.optionalObjectArray(arguments, key: key) else { return [] }
        return try objects.map { fields in
            let wrapped = JsonValue.object(fields)
            let column = try MCPArgumentDecoder.requireNonEmptyString(wrapped, key: "column")
            guard column != TableFilter.rawSQLColumn else {
                throw MCPToolExecutionError.invalidArgument(
                    String(localized: "Raw SQL filters are not available over MCP.")
                )
            }
            let rawOperator = try MCPArgumentDecoder.requireEnum(
                wrapped,
                key: "operator",
                allowed: operatorNames
            )
            guard let filterOperator = FilterOperator(rawValue: rawOperator) else {
                throw MCPToolExecutionError.invalidArgument(
                    String(localized: "That filter operator is not supported.")
                )
            }
            let value = try MCPArgumentDecoder.optionalString(wrapped, key: "value") ?? ""
            let secondValue = try MCPArgumentDecoder.optionalString(wrapped, key: "second_value")
            let caseSensitive = try MCPArgumentDecoder.optionalBool(
                wrapped,
                key: "case_sensitive",
                default: filterOperator.defaultIsCaseSensitive
            )
            let filter = TableFilter(
                columnName: column,
                filterOperator: filterOperator,
                value: value,
                secondValue: secondValue,
                isEnabled: true,
                isCaseSensitive: caseSensitive
            )
            guard filter.isValid else {
                throw MCPToolExecutionError.invalidArgument(
                    filter.validationError ?? String(localized: "That filter is incomplete.")
                )
            }
            return filter
        }
    }

    static func sort(_ arguments: JsonValue, key: String = "sort") throws -> [(column: String, descending: Bool)] {
        guard let objects = try MCPArgumentDecoder.optionalObjectArray(arguments, key: key) else { return [] }
        return try objects.map { fields in
            let wrapped = JsonValue.object(fields)
            let column = try MCPArgumentDecoder.requireNonEmptyString(wrapped, key: "column")
            let direction = try MCPArgumentDecoder.optionalEnum(
                wrapped,
                key: "direction",
                allowed: ["ascending", "descending"]
            ) ?? "ascending"
            return (column: column, descending: direction == "descending")
        }
    }

    static func logicMode(_ arguments: JsonValue, key: String = "logic") throws -> FilterLogicMode {
        let raw = try MCPArgumentDecoder.optionalEnum(arguments, key: key, allowed: ["and", "or"]) ?? "and"
        return raw == "or" ? .or : .and
    }
}
