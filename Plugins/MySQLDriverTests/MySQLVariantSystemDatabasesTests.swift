//
//  MySQLVariantSystemDatabasesTests.swift
//  MySQLDriverTests
//

import Foundation
import Testing

// TableProTests' MySQLProtocolVariantParityTests pins the app's curated lists to these same lists, so a change on
// either side fails one of the two.
struct MySQLVariantSystemDatabasesTests {
    @Test("Each MySQL-family connection type flags the system databases the app's curated table names")
    func variantListsArePinned() {
        #expect(MySQLSystemDatabases.names(forVariant: nil) == [
            "information_schema", "mysql", "performance_schema", "sys", "INFORMATION_SCHEMA", "PERFORMANCE_SCHEMA"
        ])
        #expect(MySQLSystemDatabases.names(forVariant: MySQLServerFlavor.tidbVariant) == [
            "INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys",
            "information_schema", "performance_schema"
        ])
        #expect(MySQLSystemDatabases.names(forVariant: MySQLServerFlavor.databendVariant) == [
            "information_schema", "system"
        ])
        #expect(MySQLSystemDatabases.names(forVariant: MySQLServerFlavor.oceanbaseVariant) == [
            "information_schema", "mysql", "oceanbase", "__recyclebin", "__public", "SYS", "LBACSYS", "ORAAUDITOR"
        ])
    }
}
