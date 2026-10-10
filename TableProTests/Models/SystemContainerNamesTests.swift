//
//  SystemContainerNamesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct SystemContainerNamesTests {
    private func names(_ type: DatabaseType, _ target: ContainerSwitchTarget = .database) -> SystemContainerNames {
        PluginManager.shared.systemContainerNames(for: type, target: target)
    }

    @Test("An engine that keeps case matches its system databases exactly")
    func exactEngineKeepsCase() {
        let mysql = names(.mysql)
        #expect(mysql.contains("mysql"))
        #expect(!mysql.contains("MySQL"))
    }

    @Test("Teradata and Snowflake system databases match in any case")
    func caseInsensitiveEnginesMatchAnyCase() {
        let teradata = names(.teradata)
        #expect(teradata.contains("dbc"))
        #expect(teradata.contains("SYSADMIN"))
        #expect(!teradata.contains("sales"))
        #expect(names(.snowflake).contains("snowflake_sample_data"))
    }

    @Test("The registry carries the flag only for the engines that compare without case")
    func registryCarriesTheFlag() {
        #expect(names(.teradata).ignoresCase)
        #expect(names(.snowflake).ignoresCase)
        for type in [DatabaseType.mysql, .postgresql, .cockroachdb, .redshift] {
            #expect(!names(type).ignoresCase, "\(type.rawValue)")
        }
    }

    @Test("The schema list is matched exactly on every engine")
    func schemaTargetIsExact() {
        let snowflake = names(.snowflake, .schema)
        #expect(!snowflake.ignoresCase)
        #expect(snowflake.contains("INFORMATION_SCHEMA"))
        #expect(!snowflake.contains("information_schema"))
    }

    @Test("An engine the registry does not know has no system containers")
    func unknownEngineIsEmpty() {
        let unknown = names(DatabaseType(rawValue: "SystemContainerNamesTestsUnknownEngine"))
        #expect(unknown == .empty)
        #expect(!unknown.contains("mysql"))
    }

    @Test("Rebuilding a snapshot keeps the case rule")
    func snapshotCopiesKeepTheFlag() throws {
        let teradata = try #require(PluginMetadataRegistry.shared.snapshot(for: .teradata))
        #expect(teradata.withSystemNames(databases: ["DBC"], schemas: []).schema.systemDatabaseNamesIgnoreCase)
        #expect(teradata.withSwitchRouting(from: teradata).schema.systemDatabaseNamesIgnoreCase)
    }
}
