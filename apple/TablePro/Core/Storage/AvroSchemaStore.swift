//
//  AvroSchemaStore.swift
//  TablePro
//

import Foundation

internal final class AvroSchemaStore: Sendable {
    static let shared = AvroSchemaStore(
        directory: AppStorageEnvironment.shared.supportDirectory.appendingPathComponent("AvroSchemas", isDirectory: true)
    )

    // Far past any real schema; a file this large is the wrong file.
    static let maxFileBytes = 4_000_000

    // Posted when a schema this Mac did not have is kept, so a viewer that found it missing decodes again.
    static let didRestoreSchema = Notification.Name("com.TablePro.avroSchemaStore.didRestoreSchema")
    static let schemaIDKey = "schemaID"

    private let files: SchemaFileCache<AvroSchema>

    init(directory: URL) {
        files = SchemaFileCache(directory: directory, fileExtension: "avsc") { data in
            guard let text = String(data: data, encoding: .utf8) else {
                throw AvroSchemaError(reason: String(localized: "The file is not UTF-8 text."))
            }
            return try AvroSchema.parse(text)
        }
    }

    static func isSchemaID(_ text: String) -> Bool {
        SchemaFileCache<AvroSchema>.isSchemaID(text)
    }

    static func schemaID(of text: String) -> String {
        SchemaFileCache<AvroSchema>.schemaID(of: Data(text.utf8))
    }

    func add(_ text: String) throws -> String {
        let (id, wasMissing) = try files.add(Data(text.utf8))
        if wasMissing {
            NotificationCenter.default.post(name: Self.didRestoreSchema, object: self, userInfo: [Self.schemaIDKey: id])
        }
        return id
    }

    func schema(id: String) -> AvroSchema? {
        files.schema(id: id)
    }

    var storedIDs: Set<String> {
        files.storedIDs
    }

    func removeAll(except kept: Set<String>) {
        files.removeAll(except: kept)
    }
}
