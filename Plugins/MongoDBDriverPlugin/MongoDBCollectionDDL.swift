import Foundation
import TableProPluginKit

enum MongoDBCollectionDDL {
    static let idField = "_id"
    static let unsupportedIndexTypes: Set<String> = ["GIN", "GIST", "BRIN", "SPGIST"]

    /// A collection's fields exist on the server only as a `$jsonSchema` validator. Leaving
    /// `validationLevel` and `validationAction` out keeps the server's own defaults, strict and
    /// error, which is also what Compass and Studio 3T start from.
    static func createCollectionStatement(for definition: PluginCreateTableDefinition) -> String {
        let name = MongoScriptJson.jsonString(definition.tableName)
        let fields = definition.columns.filter { !$0.name.isEmpty }
        guard fields.contains(where: { $0.name != idField }) else {
            return "db.createCollection(\(name))"
        }

        let properties = fields.map { field in
            "        \(MongoScriptJson.jsonString(field.name)): {\"bsonType\": \(bsonTypeJson(for: field))}"
        }
        var schema = ["      \"bsonType\": \"object\""]
        let required = fields.filter { !$0.isNullable && $0.name != idField }.map(\.name)
        if !required.isEmpty {
            schema.append("      \"required\": [\(required.map(MongoScriptJson.jsonString).joined(separator: ", "))]")
        }
        schema.append("      \"properties\": {\n\(properties.joined(separator: ",\n"))\n      }")

        return """
        db.createCollection(\(name), {
          "validator": {
            "$jsonSchema": {
        \(schema.joined(separator: ",\n"))
            }
          }
        })
        """
    }

    static func createIndexStatement(collection: String, index: PluginIndexDefinition) -> String? {
        guard !index.columns.isEmpty, let keyValue = indexKeyValue(for: index.indexType) else { return nil }
        let keys = index.columns
            .map { "\(MongoScriptJson.jsonString($0)): \(keyValue)" }
            .joined(separator: ", ")
        var options: [String] = []
        if !index.name.isEmpty {
            options.append("\"name\": \(MongoScriptJson.jsonString(index.name))")
        }
        if index.isUnique {
            options.append("\"unique\": true")
        }
        let accessor = MongoCollectionAccessor.expression(for: collection)
        guard !options.isEmpty else { return "\(accessor).createIndex({\(keys)})" }
        return "\(accessor).createIndex({\(keys)}, {\(options.joined(separator: ", "))})"
    }

    static func refusal(for operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .addColumn(let column):
            return columnRefusal(column)
        case .addIndex(let index), .modifyIndex(_, let index):
            return indexRefusal(index)
        case .renameCheckConstraint, .dropIndex:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Columns

    private static func bsonTypeJson(for field: PluginColumnDefinition) -> String {
        if field.name == idField {
            return "\"objectId\""
        }
        let declared = MongoDBBsonType.alias(forEditorType: field.dataType)
            ?? field.dataType.trimmingCharacters(in: .whitespaces)
        guard field.isNullable, declared != "null" else {
            return MongoScriptJson.jsonString(declared)
        }
        return "[\(MongoScriptJson.jsonString(declared)), \"null\"]"
    }

    private static func columnRefusal(_ column: PluginColumnDefinition) -> String? {
        if column.name.hasPrefix("$") || column.name.contains(".") {
            return String(
                format: String(localized: "MongoDB cannot address a field named %@. A field name cannot start with $ or contain a dot."),
                column.name
            )
        }
        guard let alias = MongoDBBsonType.alias(forEditorType: column.dataType) else {
            return String(
                format: String(localized: "%1$@ has type %2$@, which MongoDB does not have. Choose a type from the list."),
                column.name, column.dataType
            )
        }
        if column.name == idField {
            guard alias == "objectId" else {
                return String(localized: "_id must be an objectId. MongoDB generates it for every new document.")
            }
            return nil
        }
        if column.isPrimaryKey {
            return String(
                format: String(localized: "%@ cannot be the primary key. MongoDB keys every document by _id."),
                column.name
            )
        }
        return nil
    }

    // MARK: - Indexes

    private static func indexKeyValue(for indexType: String?) -> String? {
        switch indexType?.uppercased() ?? "" {
        case "", "BTREE": return "1"
        case "HASH": return "\"hashed\""
        case "FULLTEXT": return "\"text\""
        case "SPATIAL": return "\"2dsphere\""
        default: return nil
        }
    }

    private static func indexRefusal(_ index: PluginIndexDefinition) -> String? {
        let label = index.name.isEmpty ? index.columns.joined(separator: ", ") : index.name
        let usesSQLOnlyFeature = !(index.whereClause ?? "").isEmpty
            || !(index.expressions ?? []).isEmpty
            || !(index.includedColumns ?? []).isEmpty
            || !(index.columnPrefixes ?? [:]).isEmpty
        if usesSQLOnlyFeature {
            return String(
                format: String(localized: "Index %@ has a WHERE clause, an expression, included columns or a prefix length. MongoDB indexes take none of these."),
                label
            )
        }
        guard let keyValue = indexKeyValue(for: index.indexType) else {
            return String(
                format: String(localized: "MongoDB has no %@ index."),
                index.indexType ?? ""
            )
        }
        if index.columns == [idField] {
            return String(localized: "MongoDB already indexes _id.")
        }
        guard keyValue == "\"hashed\"" else { return nil }
        if index.isUnique {
            return String(localized: "A hashed index cannot be unique.")
        }
        if index.columns.count > 1 {
            return String(localized: "A hashed index takes one field.")
        }
        return nil
    }
}
