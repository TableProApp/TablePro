//
//  DatabaseTreeCapabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// `supportsDatabaseTree` decides whether the sidebar can show a database level at all.
/// Nothing pinned it before, so relaxing its connection-mode guard was unobservable.
@MainActor
@Suite("Database tree capability")
struct DatabaseTreeCapabilityTests {
    private func snapshot(forRegisteredTypeId typeId: String) -> PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId)
    }

    @Test("Networked engines that group by database or schema get a tree")
    func networkedGroupingEnginesGetTree() {
        for type in [DatabaseType.mysql, .postgresql, .mssql, .clickhouse, .cassandra] {
            #expect(
                PluginManager.shared.supportsDatabaseTree(for: type) == true,
                "\(type.rawValue) should still have a database tree"
            )
        }
    }

    /// A file holds exactly one database, so there is nothing to draw a tree from.
    @Test("File-based engines never get a tree")
    func fileBasedEnginesNeverGetTree() {
        for type in [DatabaseType.sqlite, .beancount] {
            #expect(PluginManager.shared.supportsDatabaseTree(for: type) == false)
        }
    }

    /// DuckDB is `.apiOnly` because it is embedded, not because it has one database:
    /// `ATTACH` gives it siblings. The gate excludes file-based engines, not embedded ones.
    @Test("DuckDB gets a database tree despite being apiOnly")
    func duckDBGetsTree() {
        #expect(PluginManager.shared.connectionMode(for: .duckdb) == .apiOnly)
        #expect(PluginManager.shared.supportsDatabaseSwitching(for: .duckdb) == true)
        #expect(PluginManager.shared.databaseGroupingStrategy(for: .duckdb) == .bySchema)
        #expect(PluginManager.shared.supportsDatabaseTree(for: .duckdb) == true)
    }

    /// The grouping strategy, not the connection mode, is what keeps an engine that never
    /// declared one out of the tree: `supportsDatabaseSwitching` defaults to true.
    @Test("Flat and hierarchical engines stay out of the tree whatever their mode")
    func nonGroupingEnginesStayOut() {
        let types = [DatabaseType.mongodb, .redis, .cloudflareD1, .oracle, .bigQuery]
            + [DatabaseType(rawValue: "Snowflake"), DatabaseType(rawValue: "Trino")]
        for type in types {
            #expect(
                PluginManager.shared.supportsDatabaseTree(for: type) == false,
                "\(type.rawValue) does not group by database or schema and must not get a tree"
            )
        }
    }

    /// `DatabaseType` is open, so a type with no snapshot falls back to a networked engine
    /// that groups by database. Relaxing the connection-mode guard did not change that: the
    /// fallback was already `.network`. Pinned so a future guard change has to be deliberate.
    @Test("An unknown future type keeps the optimistic tree default")
    func unknownTypeKeepsDefault() {
        let unknown = DatabaseType(rawValue: "FuturePlugin")
        #expect(PluginManager.shared.connectionMode(for: unknown) == .network)
        #expect(PluginManager.shared.supportsDatabaseSwitching(for: unknown) == true)
        #expect(PluginManager.shared.databaseGroupingStrategy(for: unknown) == .byDatabase)
        #expect(PluginManager.shared.supportsDatabaseTree(for: unknown) == true)
    }

    /// Both non-mode terms of the guard are permissive by default, so a plugin that
    /// declares only `.apiOnly` and nothing else now qualifies where it previously did
    /// not. Recorded rather than asserted as desirable: widening the guard widened this.
    @Test("An apiOnly plugin that declares no grouping qualifies for a tree")
    func apiOnlyWithDefaultsQualifies() {
        #expect(
            PluginManager.supportsDatabaseTree(
                connectionMode: .apiOnly, supportsDatabaseSwitching: true, grouping: .byDatabase
            ) == true
        )
        #expect(
            PluginManager.supportsDatabaseTree(
                connectionMode: .fileBased, supportsDatabaseSwitching: true, grouping: .byDatabase
            ) == false
        )
        #expect(
            PluginManager.supportsDatabaseTree(
                connectionMode: .apiOnly, supportsDatabaseSwitching: false, grouping: .byDatabase
            ) == false
        )
        #expect(
            PluginManager.supportsDatabaseTree(
                connectionMode: .apiOnly, supportsDatabaseSwitching: true, grouping: .flat
            ) == false
        )
    }

    /// The relaxed guard swapped `== .network` for `!= .fileBased`, so this walks every
    /// registered type rather than a sample: a file is one database, always.
    @Test("No file-based type anywhere in the registry gains a tree")
    func noFileBasedTypeGainsTree() {
        var checked = 0
        for typeId in PluginMetadataRegistry.shared.allRegisteredTypeIds() {
            guard let snap = snapshot(forRegisteredTypeId: typeId), snap.connectionMode == .fileBased else { continue }
            checked += 1
            #expect(
                PluginManager.shared.supportsDatabaseTree(for: DatabaseType(rawValue: typeId)) == false,
                "\(typeId) is file-based and must not have a database tree"
            )
        }
        #expect(checked > 0, "No file-based types found; the guard is no longer being exercised")
    }
}
