//
//  MySQLProtocolVariantParityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MySQL-protocol variants agree across the family lists")
@MainActor
struct MySQLProtocolVariantParityTests {
    nonisolated private static let variants: [DatabaseType] = [.mariadb, .tidb, .databend, .oceanbase]
    nonisolated private static let outsideMySQLDialect: Set<DatabaseType> = [.databend]

    @Test("The pinned variants are exactly the types the registry sends to the MySQL plugin")
    func variantListIsComplete() {
        let routed = DatabaseType.allKnownTypes.filter {
            $0 != .mysql && PluginMetadataRegistry.shared.pluginTypeId(for: $0.rawValue) == DatabaseType.mysql.rawValue
        }
        #expect(Set(routed) == Set(Self.variants))
    }

    @Test("Every variant is driven by the MySQL plugin", arguments: variants)
    func drivenByMySQLPlugin(type: DatabaseType) {
        #expect(PluginMetadataRegistry.shared.pluginTypeId(for: type.rawValue) == DatabaseType.mysql.rawValue)
        #expect(type.pluginTypeId == DatabaseType.mysql.rawValue)
    }

    @Test("A variant that speaks MySQL SQL is MySQL in every list keyed by dialect", arguments: variants)
    func dialectListsAgree(type: DatabaseType) {
        let speaksMySQL = !Self.outsideMySQLDialect.contains(type)
        #expect((SqlDialect.from(databaseTypeId: type.rawValue) == .mysql) == speaksMySQL)
        #expect((SQLTypeFamily.of(type) == .mysql) == speaksMySQL)
        #expect(
            (ImportTypeMapper.sqlType(for: .real, databaseType: type)
                == ImportTypeMapper.sqlType(for: .real, databaseType: .mysql)) == speaksMySQL
        )
        #expect((ForeignKeyDialect.forType(type) == ForeignKeyDialect.forType(.mysql)) == speaksMySQL)
    }

    @Test("A variant whose driver reads mysql_affected_rows holds a keyless save to its row count", arguments: variants)
    func rowCountsAgree(type: DatabaseType) {
        #expect(DataWriteRowCounts.areMeaningful(for: type) == !Self.outsideMySQLDialect.contains(type))
    }

    @Test("The plugin flavor and the registry name the same system databases")
    func systemDatabaseListsAgree() {
        let manager = PluginManager.shared
        #expect(manager.systemDatabaseNames(for: .tidb) == MySQLServerFlavor.tidb(version: nil).systemDatabaseNames)
        #expect(manager.systemDatabaseNames(for: .databend) == MySQLServerFlavor.databend.systemDatabaseNames)
        #expect(manager.systemDatabaseNames(for: .oceanbase) == MySQLServerFlavor.oceanbase(version: nil).systemDatabaseNames)
    }
}
