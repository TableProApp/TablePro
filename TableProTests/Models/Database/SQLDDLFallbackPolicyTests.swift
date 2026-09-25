//
//  SQLDDLFallbackPolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
import Testing

struct SQLDDLFallbackPolicyTests {
    @Test("Engines with SQL DDL keep the generated statement")
    func sqlEnginesFabricate() {
        for type in [
            DatabaseType.mysql, .postgresql, .sqlite, .mssql, .oracle,
            .duckdb, .cassandra, .trino, .teradata, .clickhouse, .bigQuery,
        ] {
            #expect(SQLDDLFallbackPolicy.allowsGeneratedDDL(for: type), "\(type.rawValue) should fabricate")
        }
    }

    @Test("Engines with no SQL DDL never get a generated statement")
    func nonSQLEnginesRefuse() {
        for type in [
            DatabaseType.elasticsearch, .kafka, .weaviate, .etcd,
            .redis, .mongodb, .typesense, .surrealdb, .dynamodb, .beancount,
        ] {
            #expect(!SQLDDLFallbackPolicy.allowsGeneratedDDL(for: type), "\(type.rawValue) should refuse")
        }
    }

    /// DynamoDB writes PartiQL and so declares an editor language of `.sql`, which is why the
    /// policy cannot be derived from that. Losing this case brings `TRUNCATE TABLE "orders"` back.
    @Test("PartiQL is not SQL DDL")
    @MainActor
    func dynamoDBIsExcludedDespiteSQLEditorLanguage() {
        #expect(PluginManager.shared.editorLanguage(for: .dynamodb) == .sql)
        #expect(!SQLDDLFallbackPolicy.allowsGeneratedDDL(for: .dynamodb))
    }

    /// Every engine `DatabaseType` declares must be named in one of the two lists, so an engine
    /// added without a decision fails here rather than inheriting one.
    ///
    /// The declared constants are read from the type's own source rather than from
    /// `DatabaseType.allKnownTypes`, which reads the live `PluginMetadataRegistry`: other suites
    /// register synthetic snapshots and never remove them, so under a different test order those
    /// ids would arrive here and fail a test about shipping engines.
    @Test("Every declared engine is classified deliberately")
    func everyDeclaredTypeIsClassified() throws {
        let declared = try declaredDatabaseTypes()
        #expect(declared.count > 30, "Parsed only \(declared.count) types; the scan is not reading the file")

        let named = Self.fabricatingTypes.union(SQLDDLFallbackPolicy.enginesWithoutSQLDDL)
        let unclassified = declared.subtracting(named.map(\.rawValue))
        #expect(
            unclassified.isEmpty,
            "Classify these in SQLDDLFallbackPolicyTests or the policy: \(unclassified.sorted())"
        )

        let unknown = Set(named.map(\.rawValue)).subtracting(declared)
        #expect(unknown.isEmpty, "Named but not declared by DatabaseType: \(unknown.sorted())")
    }

    private func declaredDatabaseTypes() throws -> Set<String> {
        let root = try #require(repositoryRoot)
        let source = try String(
            contentsOf: root.appendingPathComponent("TablePro/Models/Connection/DatabaseType.swift"),
            encoding: .utf8
        )
        var found: Set<String> = []
        for line in source.components(separatedBy: .newlines) {
            guard line.contains("static let"), let range = line.range(of: "DatabaseType(rawValue: \"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            found.insert(String(rest[..<end]))
        }
        return found
    }

    private static let fabricatingTypes: Set<DatabaseType> = [
        .mysql, .mariadb, .tidb, .databend, .oceanbase, .postgresql, .sqlite, .redshift,
        .cockroachdb, .pglite, .mssql, .oracle, .snowflake, .dameng, .clickhouse, .duckdb,
        .cassandra, .scylladb, .cloudflareD1, .cloudflareR2SQL, .bigQuery, .spanner,
        .libsql, .turso, .teradata, .trino,
    ]

    /// The policy lives in the app and the statement lives in the plugin, so nothing but this
    /// forces them to agree. An engine whose plugin declares a non-SQL editor language has no SQL
    /// DDL by construction and must never reach the fabricating branch.
    @Test("No plugin declaring a non-SQL editor language is left fabricating")
    func nonSQLPluginsAreAllExcluded() throws {
        let pluginsDirectory = try #require(repositoryRoot?.appendingPathComponent("Plugins"))
        let files = FileManager.default.enumerator(at: pluginsDirectory, includingPropertiesForKeys: nil)
        var offenders: [String] = []

        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains("editorLanguage: EditorLanguage = ."),
                  !source.contains("editorLanguage: EditorLanguage = .sql"),
                  let typeId = declaredDatabaseTypeId(in: source)
            else { continue }
            if SQLDDLFallbackPolicy.allowsGeneratedDDL(for: DatabaseType(rawValue: typeId)) {
                offenders.append(typeId)
            }
        }

        #expect(offenders.isEmpty, "Add to SQLDDLFallbackPolicy.enginesWithoutSQLDDL: \(offenders.sorted())")
    }

    private func declaredDatabaseTypeId(in source: String) -> String? {
        guard let range = source.range(of: "databaseTypeId = \"") else { return nil }
        let rest = source[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private var repositoryRoot: URL? {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
        }
        return nil
    }
}
