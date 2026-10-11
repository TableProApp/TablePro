//
//  MySQLProtocolVariantParityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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

    /// The app classifies a database list by the connection type's registry entry and the driver flags metadata by
    /// the same type's plugin list. Classifying by the flavor instead let a TiDB server saved as MySQL disagree.
    @Test("The registry names the system databases the plugin flags for each connection type")
    func systemDatabaseListsAgree() {
        let manager = PluginManager.shared
        #expect(manager.systemDatabaseNames(for: .mysql) == MySQLSystemDatabases.names(forVariant: nil))
        #expect(manager.systemDatabaseNames(for: .mariadb) == MySQLSystemDatabases.names(forVariant: nil))
        for type in Self.variants where type != .mariadb {
            #expect(manager.systemDatabaseNames(for: type) == MySQLSystemDatabases.names(forVariant: type.rawValue))
        }
    }
}
