import Foundation
import TableProPluginKit

enum MongoDBBsonType {
    static let aliases: [String] = [
        "double", "string", "object", "array", "binData", "objectId", "bool", "date", "null",
        "regex", "javascript", "int", "timestamp", "long", "decimal", "minKey", "maxKey", "number"
    ]

    /// `$jsonSchema` matches `bsonType` aliases case-sensitively, measured on 7.0: `ObjectId` and
    /// `String` are refused as unknown aliases, so a spelling is only ever matched here, never
    /// passed through.
    static func alias(forEditorType editorType: String) -> String? {
        let trimmed = editorType.trimmingCharacters(in: .whitespaces)
        return aliases.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    static func alias(forJsonSchemaType type: String) -> String? {
        switch type {
        case "string", "object", "array", "null", "number": return type
        case "boolean": return "bool"
        default: return nil
        }
    }

    /// A kind for the writer and the filter to type values against, or nil when the alias leaves
    /// the value's type open. Binary data has no subtype in a schema, and a column's UUID decoding
    /// is decided once from its documents, so a declaration never picks it.
    static func valueKind(forAlias alias: String) -> BsonValueKind? {
        switch alias {
        case "objectId": return .objectId
        case "string": return .string
        case "int": return .int32
        case "long": return .int64
        case "double": return .double
        case "decimal": return .decimal128
        case "date": return .date
        case "bool": return .boolean
        case "array": return .array
        case "object": return .document
        default: return nil
        }
    }
}

struct MongoDBDeclaredField: Equatable, Sendable {
    let name: String
    let bsonTypes: [String]
    let isRequired: Bool
    let allowedValues: [String]?
    /// Whether the validator lets the field hold null. Separate from `isRequired`, which is about
    /// the field being there at all: a required field typed `["date", "null"]` takes null, and an
    /// optional field typed `string` refuses it.
    var admitsNull = true

    var valueKind: BsonValueKind? {
        let valueTypes = bsonTypes.filter { $0 != "null" }
        guard valueTypes.count == 1, let only = valueTypes.first else { return nil }
        return MongoDBBsonType.valueKind(forAlias: only)
    }

    func columnTypeName(representation: MongoDBUuidRepresentation) -> String {
        if let valueKind {
            return BsonDocumentFlattener.typeName(for: valueKind, representation: representation)
        }
        let valueTypes = bsonTypes.filter { $0 != "null" }
        if valueTypes == ["binData"] {
            return BsonDocumentFlattener.typeName(for: .binary(subtype: 0), representation: representation)
        }
        return valueTypes.first ?? "null"
    }
}

/// The columns a collection presents: the fields its documents hold, then the fields its
/// validator declares that no document in hand holds yet. A new collection has no documents, and
/// sampling alone showed it as `_id` and nothing else.
enum MongoDBCollectionShape {
    static func emptyCollectionColumns(declaring schema: MongoDBCollectionSchema) -> [String] {
        [MongoDBCollectionDDL.idField] + schema.fields.map(\.name).filter { $0 != MongoDBCollectionDDL.idField }
    }

    static func declaredColumnsMissing(from sampled: [String], schema: MongoDBCollectionSchema) -> [String] {
        let present = Set(sampled)
        return schema.fields.map(\.name).filter { !present.contains($0) }
    }
}

struct MongoDBCollectionSchema: Equatable, Sendable {
    let fields: [MongoDBDeclaredField]
    /// Whether a field the validator's `properties` do not name may hold null: an
    /// `additionalProperties` schema decides it for every such field.
    var undeclaredFieldsAdmitNull = true
    /// A rule this reader does not model reaches every field: a combinator, `patternProperties`,
    /// `dependencies` or an `enum` over the whole document, or a query operator beside
    /// `$jsonSchema`. Each can refuse null in any field, so none is taken to admit it.
    var hasUnmodeledRule = false
    /// False for `validationAction: "warn"` and `validationLevel: "off"`, where the server stores
    /// what the validator would refuse.
    var isEnforced = true

    static let empty = MongoDBCollectionSchema(fields: [])

    var isEmpty: Bool { fields.isEmpty }

    func field(named name: String) -> MongoDBDeclaredField? {
        fields.first { $0.name == name }
    }

    /// Whether the server takes null in this field, which is what offers **Set Value > NULL**.
    func admitsNull(fieldNamed name: String) -> Bool {
        guard isEnforced else { return true }
        guard !hasUnmodeledRule else { return false }
        return field(named: name)?.admitsNull ?? undeclaredFieldsAdmitNull
    }

    var valueKinds: [String: BsonValueKind] {
        var kinds: [String: BsonValueKind] = [:]
        for field in fields {
            guard let kind = field.valueKind else { continue }
            kinds[field.name] = kind
        }
        return kinds
    }

    var allowedValues: [String: [String]] {
        var values: [String: [String]] = [:]
        for field in fields {
            guard let allowed = field.allowedValues else { continue }
            values[field.name] = allowed
        }
        return values
    }

    /// Bounded on the server, because the read runs after a find on the session driver and a
    /// stalled catalog would hold every later statement on the connection behind it.
    static let listCollectionsTimeoutMS = 5_000

    static func listCollectionsCommand(for collection: String) -> String {
        "{\"listCollections\": 1, \"filter\": {\"name\": \(MongoScriptJson.jsonString(collection))}, "
            + "\"maxTimeMS\": \(listCollectionsTimeoutMS)}"
    }

    /// Reads a `listCollections` reply's first collection. The reply is walked as text because the
    /// order of `properties` is the order the fields were declared in, and decoding into a
    /// dictionary loses it.
    static func parse(listCollectionsReply reply: String) -> MongoDBCollectionSchema {
        guard let cursor = MongoScriptJson.member(of: reply, key: "cursor"),
              let batch = MongoScriptJson.member(of: cursor, key: "firstBatch"),
              let collection = MongoScriptJson.topLevelElements(batch).first,
              let options = MongoScriptJson.member(of: collection, key: "options"),
              let validator = MongoScriptJson.member(of: options, key: "validator") else {
            return .empty
        }
        var schema = MongoScriptJson.member(of: validator, key: "$jsonSchema").map { parse(jsonSchema: $0) } ?? .empty
        if MongoScriptJson.members(of: validator).contains(where: { $0.key != "$jsonSchema" }) {
            schema.hasUnmodeledRule = true
        }
        let settings = decodeObject(options) ?? [:]
        schema.isEnforced = settings["validationAction"] as? String != "warn"
            && settings["validationLevel"] as? String != "off"
        return schema
    }

    static func parse(jsonSchema: String) -> MongoDBCollectionSchema {
        guard let schema = decodeObject(jsonSchema) else { return .empty }
        return MongoDBCollectionSchema(
            fields: declaredFields(in: schema, text: jsonSchema),
            undeclaredFieldsAdmitNull: undeclaredFieldsAdmitNull(schema["additionalProperties"]),
            hasUnmodeledRule: documentWideRules.contains { schema[$0] != nil }
        )
    }

    private static func declaredFields(in schema: [String: Any], text: String) -> [MongoDBDeclaredField] {
        guard let properties = schema["properties"] as? [String: Any],
              let propertiesText = MongoScriptJson.member(of: text, key: "properties") else {
            return []
        }
        let required = Set(schema["required"] as? [String] ?? [])
        return orderedKeys(of: propertiesText, in: properties).compactMap { name -> MongoDBDeclaredField? in
            guard let spec = properties[name] as? [String: Any] else { return nil }
            return MongoDBDeclaredField(
                name: name,
                bsonTypes: declaredTypes(in: spec),
                isRequired: required.contains(name),
                allowedValues: stringEnum(spec["enum"]),
                admitsNull: admitsNull(spec)
            )
        }
    }

    private static func orderedKeys(of objectText: String, in decoded: [String: Any]) -> [String] {
        var seen = Set<String>()
        let textual = MongoScriptJson.members(of: objectText).map(\.key).filter {
            decoded[$0] != nil && seen.insert($0).inserted
        }
        return textual + decoded.keys.filter { !seen.contains($0) }.sorted()
    }

    /// An `enum` of strings with no type of its own still only admits strings, and typing the field
    /// as one is what keeps `"1"` from being written back as the number 1 and refused.
    private static func declaredTypes(in spec: [String: Any]) -> [String] {
        if let single = spec["bsonType"] as? String { return [single] }
        if let many = spec["bsonType"] as? [String] { return many }
        if let single = spec["type"] as? String { return [MongoDBBsonType.alias(forJsonSchemaType: single)].compactMap { $0 } }
        if let many = spec["type"] as? [String] { return many.compactMap(MongoDBBsonType.alias(forJsonSchemaType:)) }
        if stringEnum(spec["enum"]) != nil { return ["string"] }
        return []
    }

    /// The server applies every keyword of a field's rule, so null passes only when each one that
    /// can refuse it lets it through: a declared type has to list null, and an `enum` has to hold
    /// it. A combinator is not modeled and is taken to refuse null. The keywords for strings,
    /// numbers, arrays and documents never see null, measured on 7.0 for `minLength` and `pattern`.
    private static func admitsNull(_ spec: [String: Any]) -> Bool {
        let typeAdmitsNull = (spec["bsonType"] == nil && spec["type"] == nil) || declaredTypes(in: spec).contains("null")
        let enumAdmitsNull = (spec["enum"] as? [Any])?.contains { $0 is NSNull } ?? true
        return typeAdmitsNull && enumAdmitsNull && !unmodeledConstraints.contains { spec[$0] != nil }
    }

    private static let unmodeledConstraints = ["anyOf", "oneOf", "allOf", "not"]

    private static let documentWideRules = unmodeledConstraints + ["dependencies", "patternProperties", "enum"]

    private static func undeclaredFieldsAdmitNull(_ additionalProperties: Any?) -> Bool {
        if let spec = additionalProperties as? [String: Any] { return admitsNull(spec) }
        return additionalProperties as? Bool ?? true
    }

    private static func stringEnum(_ value: Any?) -> [String]? {
        guard let array = value as? [Any], !array.isEmpty,
              array.allSatisfy({ $0 is String }) else { return nil }
        return array.compactMap { $0 as? String }
    }

    private static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
