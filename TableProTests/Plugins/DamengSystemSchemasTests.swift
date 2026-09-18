//
//  DamengSystemSchemasTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Dameng system schemas")
struct DamengSystemSchemasTests {
    @Test("The app lists the same system schemas the plugin does")
    func curatedListMatchesThePlugin() {
        let curated = PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: "Dameng")?.schema.systemSchemaNames
        #expect(curated == DamengSystemSchemas.listed)
    }

    /// DM8 gives every user a default schema named after it, so a `SYSDBA` login's own tables land in `SYSDBA`.
    @Test("SYSDBA lists with the user's schemas")
    func sysdbaIsNotListedAsSystem() {
        #expect(!DamengSystemSchemas.listed.contains("SYSDBA"))
    }

    @Test("Every listed system schema, SYSDBA and SYSDBO are refused a drop")
    func dropGuardCoversListedAndAdministratorSchemas() {
        for name in DamengSystemSchemas.listed + ["SYSDBA", "SYSDBO"] {
            #expect(DamengSystemSchemas.isProtectedFromDrop(name), "\(name) must not be dropped")
        }
        #expect(!DamengSystemSchemas.isProtectedFromDrop("APP"))
    }

    /// A DM8 instance created case-insensitive treats `sys` and `SYS` as one schema.
    @Test("The drop guard matches any spelling")
    func dropGuardIgnoresCase() {
        #expect(DamengSystemSchemas.isProtectedFromDrop("sys"))
        #expect(DamengSystemSchemas.isProtectedFromDrop("SysDba"))
    }
}
