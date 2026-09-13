//
//  StructureColumnFieldRegistrationTests.swift
//  TableProTests
//
//  MySQL and MariaDB share one plugin but are registered separately: MariaDB is an
//  additional type id, and a variant adopts the app's curated snapshot wholesale rather
//  than the one built from the plugin. A field added to only one of the declarations
//  therefore reaches only one of the two engines.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("Structure column field registration")
struct StructureColumnFieldRegistrationTests {
    @Test("MySQL and MariaDB expose the same structure fields")
    func mysqlAndMariaDBAgree() {
        let mysql = PluginManager.shared.structureColumnFields(for: .mysql)
        let mariadb = PluginManager.shared.structureColumnFields(for: .mariadb)
        let tidb = PluginManager.shared.structureColumnFields(for: .tidb)
        let oceanbase = PluginManager.shared.structureColumnFields(for: .oceanbase)
        #expect(Set(mysql) == Set(mariadb))
        #expect(Set(mysql) == Set(tidb))
        #expect(Set(mysql) == Set(oceanbase))
    }

    @Test("MySQL-protocol engines with on update offer it", arguments: [DatabaseType.mysql, .mariadb, .tidb, .oceanbase])
    func onUpdateIsOffered(databaseType: DatabaseType) {
        #expect(PluginManager.shared.structureColumnFields(for: databaseType).contains(.onUpdate))
    }

    @Test("On update is ordered next to the default it complements")
    func onUpdateFollowsDefaultValue() {
        let fields = StructureRowProvider.orderedFields(for: .mysql, serverSupport: .unrestricted)
        guard let defaultIndex = fields.firstIndex(of: .defaultValue),
              let onUpdateIndex = fields.firstIndex(of: .onUpdate) else {
            Issue.record("MySQL is missing the default or on update field")
            return
        }
        #expect(onUpdateIndex == defaultIndex + 1)
    }

    /// Neither engine declared its own list, so both inherited the `DriverPlugin` fallback and
    /// showed a Default and an Auto Inc cell for a grammar that has neither. ScyllaDB is registered
    /// as its own type id with its own curated snapshot, so fixing one does not fix the other.
    @Test(
        "CQL engines offer neither a default nor auto increment",
        arguments: [DatabaseType.cassandra, .scylladb]
    )
    func cqlEnginesOfferNoDefault(databaseType: DatabaseType) {
        let fields = PluginManager.shared.structureColumnFields(for: databaseType)
        #expect(!fields.contains(.defaultValue), "\(databaseType.rawValue)")
        #expect(!fields.contains(.autoIncrement), "\(databaseType.rawValue)")
    }

    @Test("Engines that do not support the attribute never offer it")
    func onUpdateIsEngineScoped() {
        for databaseType in [DatabaseType.postgresql, .sqlite, .clickhouse, .databend] {
            #expect(!PluginManager.shared.structureColumnFields(for: databaseType).contains(.onUpdate))
        }
    }

    /// Adding the generated-column pair to the Postgres family replaced `.autoIncrement` instead
    /// of joining it (#2557), so a `SERIAL` column lost its Auto Increment flag in the structure
    /// editor while `PostgreSQLPluginDriver` went on generating the DDL for one. Redshift is in
    /// the list as the control: it never gained the generated fields and never lost this one.
    @Test(
        "The Postgres family offers auto increment beside the generated fields",
        arguments: [DatabaseType.postgresql, .cockroachdb, .pglite, .redshift]
    )
    func autoIncrementSurvivesTheGeneratedFields(databaseType: DatabaseType) {
        #expect(PluginManager.shared.structureColumnFields(for: databaseType).contains(.autoIncrement))
    }

    /// The columns tab reads its dropdown options by looking each boolean field up in the ordered
    /// list, so a field the engine stops declaring silently loses its editor rather than failing.
    @Test(
        "Every boolean field an engine declares resolves to a column",
        arguments: [DatabaseType.postgresql, .mysql, .sqlite, .cockroachdb, .pglite]
    )
    func declaredBooleanFieldsResolve(databaseType: DatabaseType) {
        let ordered = StructureRowProvider.orderedFields(for: databaseType, serverSupport: .unrestricted)
        let declared = Set(PluginManager.shared.structureColumnFields(for: databaseType))
        for field in [StructureColumnField.nullable, .autoIncrement, .onUpdate] where declared.contains(field) {
            #expect(ordered.contains(field), "\(databaseType.rawValue) declares \(field) but cannot order it")
        }
    }

    @Test("Every declared field has a display name")
    func everyFieldHasDisplayName() {
        for field in StructureColumnField.allCases {
            #expect(!field.displayName.isEmpty)
        }
    }
}
