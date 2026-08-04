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
        #expect(Set(mysql) == Set(mariadb))
    }

    @Test("MySQL and MariaDB both offer the on update field", arguments: [DatabaseType.mysql, .mariadb])
    func onUpdateIsOffered(databaseType: DatabaseType) {
        #expect(PluginManager.shared.structureColumnFields(for: databaseType).contains(.onUpdate))
    }

    @Test("On update is ordered next to the default it complements")
    func onUpdateFollowsDefaultValue() {
        let fields = StructureRowProvider.orderedFields(for: .mysql)
        guard let defaultIndex = fields.firstIndex(of: .defaultValue),
              let onUpdateIndex = fields.firstIndex(of: .onUpdate) else {
            Issue.record("MySQL is missing the default or on update field")
            return
        }
        #expect(onUpdateIndex == defaultIndex + 1)
    }

    @Test("Engines that do not support the attribute never offer it")
    func onUpdateIsEngineScoped() {
        for databaseType in [DatabaseType.postgresql, .sqlite, .clickhouse] {
            #expect(!PluginManager.shared.structureColumnFields(for: databaseType).contains(.onUpdate))
        }
    }

    @Test("Every declared field has a display name")
    func everyFieldHasDisplayName() {
        for field in StructureColumnField.allCases {
            #expect(!field.displayName.isEmpty)
        }
    }
}
