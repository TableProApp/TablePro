//
//  NetworkPaneDatabaseFieldTests.swift
//  TableProTests
//
//  Whether the form renders a built-in Database field is one predicate, and the form must never
//  require a value it does not render. Both used to be spelled out separately in four places.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection form database field")
@MainActor
struct NetworkPaneDatabaseFieldTests {
    private func model(for type: DatabaseType) -> NetworkPaneViewModel {
        let model = NetworkPaneViewModel()
        model.type = type
        return model
    }

    /// Issue #2234: the field was gated on requiresAuthentication, which MongoDB declares false,
    /// so a MongoDB connection could not name a database and had to load the whole list instead.
    @Test(
        "A network driver that takes a container name renders the field",
        arguments: [
            DatabaseType.mongodb,
            DatabaseType.cassandra,
            DatabaseType(rawValue: "Trino"),
            DatabaseType.mysql,
            DatabaseType.postgresql,
        ]
    )
    func networkDriversRenderTheField(type: DatabaseType) {
        #expect(model(for: type).showsBuiltInDatabaseField)
    }

    /// Oracle and Dameng show a Schema field today while declaring supportsDatabaseSwitching
    /// false, so that flag cannot be the gate either.
    @Test(
        "A network driver without runtime database switching keeps its field",
        arguments: [DatabaseType.oracle, DatabaseType.dameng]
    )
    func networkDriversWithoutSwitchingKeepTheField(type: DatabaseType) {
        #expect(model(for: type).showsBuiltInDatabaseField)
    }

    /// Redis numbers its databases through its own field, etcd has no container, and
    /// Elasticsearch reports exactly one called `default` and never reads the value.
    @Test(
        "A driver that names its container elsewhere, or has none, opts out",
        arguments: [DatabaseType.redis, DatabaseType.etcd, DatabaseType.elasticsearch]
    )
    func optedOutDriversHideTheField(type: DatabaseType) {
        #expect(!model(for: type).showsBuiltInDatabaseField)
    }

    /// These are apiOnly and declare no database switching, so the field stays hidden. Gating
    /// the whole form on hidesBuiltInDatabase alone would have started showing it here.
    @Test(
        "An apiOnly driver without database switching keeps the field hidden",
        arguments: [DatabaseType.bigQuery, DatabaseType.dynamodb, DatabaseType.libsql]
    )
    func apiOnlyDriversWithoutSwitchingHideTheField(type: DatabaseType) {
        #expect(!model(for: type).showsBuiltInDatabaseField)
    }

    // MARK: - Never require what is not rendered

    /// A new DuckDB connection could not be saved: validation demanded a database name while the
    /// form rendered no field able to supply one, so Save and Test stayed disabled forever.
    @Test("DuckDB neither renders nor requires the built-in database field")
    func duckDBIsSaveable() {
        let model = model(for: .duckdb)
        #expect(!model.showsBuiltInDatabaseField)
        #expect(!model.requiresDatabaseValue)

        model.name = "Analytics"
        #expect(!model.validationIssues.contains { $0.localizedCaseInsensitiveContains("database") })
    }

    @Test("A named database is optional for a network driver, so a blank one still validates")
    func networkDatabaseStaysOptional() {
        let model = model(for: .mongodb)
        model.name = "Cluster"
        model.database = ""
        #expect(model.showsBuiltInDatabaseField)
        #expect(!model.requiresDatabaseValue)
        #expect(!model.validationIssues.contains { $0.localizedCaseInsensitiveContains("database") })
    }

    @Test("Every type that requires a database value also renders a field for it")
    func requiredImpliesRendered() {
        let types: [DatabaseType] = [
            .mysql, .postgresql, .mongodb, .cassandra, .oracle, .dameng,
            .redis, .etcd, .elasticsearch, .duckdb, .bigQuery, .dynamodb, .libsql,
        ]
        for type in types {
            let model = model(for: type)
            guard model.requiresDatabaseValue, model.connectionMode != .fileBased else { continue }
            #expect(model.showsBuiltInDatabaseField, "\(type.rawValue) requires a database it cannot render")
        }
    }
}
