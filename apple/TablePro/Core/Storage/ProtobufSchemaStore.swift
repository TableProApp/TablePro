//
//  ProtobufSchemaStore.swift
//  TablePro
//

import Foundation

internal final class ProtobufSchemaStore: Sendable {
    static let shared = ProtobufSchemaStore(
        directory: AppStorageEnvironment.shared.supportDirectory.appendingPathComponent("ProtobufSchemas", isDirectory: true)
    )

    static let maxFileBytes = 4_000_000

    static let didRestoreSchema = Notification.Name("com.TablePro.protobufSchemaStore.didRestoreSchema")
    static let schemaIDKey = "schemaID"

    private let files: SchemaFileCache<ProtobufSchema>

    init(directory: URL) {
        files = SchemaFileCache(directory: directory, fileExtension: "pbschema") { try ProtobufSchema.parse($0) }
    }

    func add(_ contents: Data) throws -> String {
        let (id, wasMissing) = try files.add(contents)
        if wasMissing {
            NotificationCenter.default.post(
                name: Self.didRestoreSchema, object: self, userInfo: [Self.schemaIDKey: id]
            )
        }
        return id
    }

    func schema(id: String) -> ProtobufSchema? {
        files.schema(id: id)
    }

    var storedIDs: Set<String> {
        files.storedIDs
    }

    func removeAll(except kept: Set<String>) {
        files.removeAll(except: kept)
    }
}
