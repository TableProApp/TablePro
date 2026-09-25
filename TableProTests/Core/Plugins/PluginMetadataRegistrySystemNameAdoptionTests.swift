//
//  PluginMetadataRegistrySystemNameAdoptionTests.swift
//  TableProTests
//
//  A plugin's own snapshot replaces the curated entry when it loads, so a published plugin that lists fewer system
//  names than the app, or none, took them away. No plugin loads under XCTest, so these build the plugin's snapshot
//  from the curated one the way a published plugin would report it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PluginMetadataRegistrySystemNameAdoptionTests {
    private func curated(_ typeId: String) -> PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId)
    }

    @Test("A published Oracle plugin that lists no system schemas keeps the app's")
    func emptyPluginSchemaListKeepsCuratedSchemas() {
        guard let oracle = curated("Oracle") else {
            Issue.record("Registry default for Oracle missing")
            return
        }
        var published = oracle.withSystemNames(
            databases: ["SYS", "SYSTEM", "OUTLN", "DBSNMP", "APPQOSSYS", "WMSYS", "XDB"],
            schemas: []
        )

        PluginMetadataRegistry.adoptCuratedSystemNames(&published, registryDefault: oracle)

        #expect(published.schema.systemSchemaNames == oracle.schema.systemSchemaNames)
        #expect(Set(published.schema.systemDatabaseNames) == Set(oracle.schema.systemDatabaseNames))
    }

    @Test("A name either side lists counts, the plugin's names first and none twice")
    func namesAreUnitedInOrder() {
        guard let base = curated("Dameng") else {
            Issue.record("Registry default for Dameng missing")
            return
        }
        var plugin = base.withSystemNames(databases: ["b", "a"], schemas: ["S1"])
        let registryDefault = base.withSystemNames(databases: ["a", "c"], schemas: ["S2", "S1"])

        PluginMetadataRegistry.adoptCuratedSystemNames(&plugin, registryDefault: registryDefault)

        #expect(plugin.schema.systemDatabaseNames == ["b", "a", "c"])
        #expect(plugin.schema.systemSchemaNames == ["S1", "S2"])
    }

    @Test("A plugin that already lists every curated name is left as it reported")
    func completePluginListIsUnchanged() {
        guard let base = curated("Dameng") else {
            Issue.record("Registry default for Dameng missing")
            return
        }
        var plugin = base.withSystemNames(databases: [], schemas: ["CTISYS", "SYS", "SYSAUDITOR", "SYSSSO", "SYSJOB", "SYSGEO2"])

        PluginMetadataRegistry.adoptCuratedSystemNames(&plugin, registryDefault: base)

        #expect(plugin.schema.systemSchemaNames == ["CTISYS", "SYS", "SYSAUDITOR", "SYSSSO", "SYSJOB", "SYSGEO2"])
    }

    /// Measured on Oracle AI Database 26ai Free: `ALL_USERS` reports these with `ORACLE_MAINTAINED = 'Y'`, and the
    /// administrator account a PDB is created with, `PDBADMIN`, with `N`.
    @Test("Oracle's own schemas are system schemas, and the accounts users create are not")
    func oracleMaintainedSchemasAreSystem() {
        let schemas = PluginMetadataRegistry.shared.snapshot(for: .oracle)?.schema.systemSchemaNames ?? []
        for name in ["SYS", "SYSTEM", "XDB", "AUDSYS", "MDSYS", "CTXSYS", "GSMADMIN_INTERNAL", "XS$NULL"] {
            #expect(schemas.contains(name), "\(name) is Oracle-maintained")
        }
        for name in ["PDBADMIN", "OPS$ORACLE", "HR", "SCOTT"] {
            #expect(!schemas.contains(name), "\(name) is not Oracle-maintained")
        }
    }

    @Test("Oracle names the same schemas whether it is asked for databases or schemas")
    func oracleListsAgree() {
        let schema = PluginMetadataRegistry.shared.snapshot(for: .oracle)?.schema
        #expect(schema?.systemDatabaseNames == schema?.systemSchemaNames)
    }
}
