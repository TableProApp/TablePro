import Foundation
import TableProPluginKit

nonisolated enum MongoExportDocument {
    static func read(
        canonicalJSON: String,
        dictionary: [String: Any],
        representation: MongoDBUuidRepresentation
    ) throws -> PluginExportDocument {
        let document = try MongoDocumentText(parsing: canonicalJSON)
        let fields = try document.members.map { member in
            guard let value = dictionary[member.key] else {
                throw PluginExportError.exportFailed("A document field could not be read")
            }
            let kind = kind(of: member.value, decoded: value, representation: representation)
            let cell: PluginCellValue
            if value is [String: Any] || value is [Any] {
                cell = .text(BsonDocumentFlattener.nestedDisplayText(member.value))
            } else {
                cell = BsonDocumentFlattener.cellValue(for: value, kind: kind, representation: representation)
            }
            return PluginExportField(
                name: member.key, canonicalJSON: member.value.compactText,
                typeName: BsonDocumentFlattener.typeName(for: kind, representation: representation), cellValue: cell
            )
        }
        return PluginExportDocument(fields: fields)
    }

    static func read(_ documents: MongoReadDocuments, representation: MongoDBUuidRepresentation) throws -> [PluginExportDocument] {
        guard documents.texts.count == documents.dictionaries.count else {
            throw PluginExportError.exportFailed("The result has no stored documents")
        }
        return try zip(documents.texts, documents.dictionaries).map {
            try read(canonicalJSON: $0, dictionary: $1, representation: representation)
        }
    }

    private static func kind(
        of canonical: MongoDocumentText.Value,
        decoded: Any,
        representation: MongoDBUuidRepresentation
    ) -> BsonValueKind {
        switch MongoExtendedJsonType.name(of: canonical) {
        case "int": return .int32
        case "long": return .int64
        case "double": return .double
        case "decimal": return .decimal128
        case "objectId": return .objectId
        case "date": return .date
        case "bool": return .boolean
        case "null": return .null
        case "string": return .string
        case "array": return .array
        case "object": return .document
        default: return BsonDocumentFlattener.valueKind(for: decoded, representation: representation)
        }
    }
}
