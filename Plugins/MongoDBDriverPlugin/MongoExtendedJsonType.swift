import Foundation

/// The name MongoDB's `$type` operator gives a value, read from the value's canonical Extended JSON.
///
/// Canonical Extended JSON writes every typed value as a one-field object whose key starts with `$`,
/// so the key alone says the type. An object whose first key starts with `$` and is none of these is
/// an ordinary subdocument, which is what the server stores it as.
enum MongoExtendedJsonType {
    static func name(of value: MongoDocumentText.Value) -> String? {
        switch value {
        case .array:
            return "array"
        case .string:
            return "string"
        case .literal(let literal):
            return literalTypes[literal]
        case .number:
            return nil
        case .object(let members):
            return objectTypeName(members)
        }
    }

    static func isContainer(_ value: MongoDocumentText.Value) -> Bool {
        let type = name(of: value)
        return type == "object" || type == "array"
    }

    /// A subdocument whose first field is an operator rather than a type marker, which a query
    /// reads as a condition rather than a value to match.
    static func isQueryOperator(_ value: MongoDocumentText.Value) -> Bool {
        guard case .object(let members) = value, let first = members.first else { return false }
        return first.key.hasPrefix("$") && name(of: value) == "object"
    }

    private static let literalTypes = ["true": "bool", "false": "bool", "null": "null"]

    private static let wrapperTypes: [String: String] = [
        "$oid": "objectId",
        "$symbol": "symbol",
        "$numberInt": "int",
        "$numberLong": "long",
        "$numberDouble": "double",
        "$numberDecimal": "decimal",
        "$binary": "binData",
        "$code": "javascript",
        "$timestamp": "timestamp",
        "$regularExpression": "regex",
        "$dbPointer": "dbPointer",
        "$date": "date",
        "$minKey": "minKey",
        "$maxKey": "maxKey",
        "$undefined": "undefined"
    ]

    private static func objectTypeName(_ members: [MongoDocumentText.Member]) -> String {
        guard let first = members.first, let wrapped = wrapperTypes[first.key] else { return "object" }
        if members.count == 1 { return wrapped }
        if first.key == "$code", members.count == 2, members[1].key == "$scope" { return "javascriptWithScope" }
        return "object"
    }
}
