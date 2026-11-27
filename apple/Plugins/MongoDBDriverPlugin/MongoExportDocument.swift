import Foundation
import TableProPluginKit

nonisolated enum MongoExportDocument {
    /// The document's stored size comes with it, from the length prefix its BSON opens with.
    static func read(
        canonical document: MongoDocumentText,
        dictionary: [String: Any],
        representation: MongoDBUuidRepresentation,
        bsonSizeUpperBound size: Int?
    ) throws -> PluginExportDocument {
        let fields = try document.members.map { member in
            guard let value = dictionary[member.key] else {
                throw PluginExportError.exportFailed(String(localized: "A document field could not be read", bundle: .main))
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
        return PluginExportDocument(fields: fields, bsonSizeUpperBound: size)
    }

    static func read(_ document: MongoReadDocument, representation: MongoDBUuidRepresentation) throws -> PluginExportDocument {
        guard let canonical = document.canonical else {
            throw PluginExportError.exportFailed(String(localized: "The result has no stored documents", bundle: .main))
        }
        return try read(
            canonical: canonical, dictionary: document.dictionary,
            representation: representation, bsonSizeUpperBound: document.bsonSize
        )
    }

    static func read(_ documents: MongoReadDocuments, representation: MongoDBUuidRepresentation) throws -> [PluginExportDocument] {
        try documents.dictionaries.indices.map { index in
            guard let canonical = documents.canonical[index] else {
                throw PluginExportError.exportFailed(String(localized: "The result has no stored documents", bundle: .main))
            }
            return try read(
                canonical: canonical, dictionary: documents.dictionaries[index],
                representation: representation, bsonSizeUpperBound: documents.bsonSizes[index]
            )
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
