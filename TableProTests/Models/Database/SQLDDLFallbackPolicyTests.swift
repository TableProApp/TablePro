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
            .duckdb, .cassandra, .trino, .teradata, .clickhouse, .bigQuery, .sapHana,
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

    /// Every engine in the curated table must be named in one of the two lists, so an engine added
    /// without a decision fails here. The live registry also holds synthetic engines other suites add.
    @Test("Every shipping engine is classified deliberately")
    func everyShippingEngineIsClassified() {
        let shipping = Set(PluginMetadataRegistry.shared.builtInDefaults().map(\.typeId))
        #expect(shipping.count > 30, "The curated table lists only \(shipping.count) engines")

        let named = Set(Self.fabricatingTypes.union(SQLDDLFallbackPolicy.enginesWithoutSQLDDL).map(\.rawValue))
        let unclassified = shipping.subtracting(named)
        #expect(
            unclassified.isEmpty,
            "Classify these in SQLDDLFallbackPolicyTests or the policy: \(unclassified.sorted())"
        )

        let unknown = named.subtracting(shipping)
        #expect(unknown.isEmpty, "Named but not in the curated table: \(unknown.sorted())")
    }

    private static let fabricatingTypes: Set<DatabaseType> = [
        .mysql, .mariadb, .tidb, .databend, .oceanbase, .postgresql, .sqlite, .redshift,
        .cockroachdb, .pglite, .mssql, .oracle, .snowflake, .dameng, .clickhouse, .duckdb,
        .cassandra, .scylladb, .cloudflareD1, .cloudflareR2SQL, .bigQuery, .spanner,
        .libsql, .turso, .teradata, .trino, .sapHana,
    ]

    /// The policy lives in the app and the statement lives in the plugin. An engine with a non-SQL
    /// editor language has no SQL DDL by construction and must never reach the fabricating branch.
    @Test("No engine with a non-SQL editor language is left fabricating")
    func nonSQLEnginesAreAllExcluded() {
        let offenders = PluginMetadataRegistry.shared.builtInDefaults()
            .filter { $0.snapshot.editorLanguage != .sql }
            .map(\.typeId)
            .filter { SQLDDLFallbackPolicy.allowsGeneratedDDL(for: DatabaseType(rawValue: $0)) }
        #expect(offenders.isEmpty, "Add to SQLDDLFallbackPolicy.enginesWithoutSQLDDL: \(offenders.sorted())")
    }
}
