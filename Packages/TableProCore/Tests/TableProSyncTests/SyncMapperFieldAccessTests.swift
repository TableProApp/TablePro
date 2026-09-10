import Foundation
import Testing

@Suite("Sync mappers only reach CKRecord fields through the schema gate")
struct SyncMapperFieldAccessTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let mapperPaths = [
        "TablePro/Core/Sync/SyncRecordMapper.swift",
        "Packages/TableProCore/Sources/TableProSync/SyncRecordMapper.swift"
    ]

    @Test("Every mapper the check covers is where the check expects it")
    func mappersExist() {
        for path in Self.mapperPaths {
            let url = Self.repositoryRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), """
            \(path) has moved, so this check would pass vacuously. Update mapperPaths.
            """)
        }
    }

    @Test("No mapper writes a CKRecord field by raw string", arguments: mapperPaths)
    func mappersUseTypedFields(path: String) throws {
        let url = Self.repositoryRoot.appendingPathComponent(path)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }

        let offenders = source
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { $0.element.contains("record[\"") }
            .map { "\(path):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        #expect(offenders.isEmpty, """
        Raw-string CKRecord field access bypasses the production-schema gate, which is exactly \
        how FavoriteTable, SQLFavorite, SQLFavoriteFolder and SSHProfile.jumpHostsJson reached \
        users without ever being deployed. Declare the field in its SyncSchemaField enum and go \
        through record.fields(_:) instead.
        \(offenders.joined(separator: "\n"))
        """)
    }
}
