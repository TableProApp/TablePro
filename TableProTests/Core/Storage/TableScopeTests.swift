//
//  TableScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableScope")
struct TableScopeTests {
    @Test("storageComponent distinguishes schemas")
    func schemaDistinguishesKey() {
        let conn = UUID()
        let publicScope = TableScope(connectionId: conn, database: "shop", schema: "public", table: "orders")
        let archiveScope = TableScope(connectionId: conn, database: "shop", schema: "archive", table: "orders")
        #expect(publicScope.storageComponent != archiveScope.storageComponent)
    }

    @Test("storageComponent survives separator characters in identifiers")
    func encodesSeparators() {
        let conn = UUID()
        let dotted = TableScope(connectionId: conn, database: "a.b", schema: nil, table: "c")
        let split = TableScope(connectionId: conn, database: "a", schema: "b", table: "c")
        #expect(dotted.storageComponent != split.storageComponent)
    }

    @Test("CompositeStorageKey matches TableScope.storageComponent")
    func compositeKeyEquivalence() {
        let conn = UUID()
        let scope = TableScope(connectionId: conn, database: "db", schema: "public", table: "t")
        let composite = CompositeStorageKey.make(
            connectionId: conn,
            databaseName: "db",
            schemaName: "public",
            tableName: "t"
        )
        #expect(composite == scope.storageComponent)
    }

    @Test("Scoped preference keys are namespaced")
    func scopedKeysNamespaced() {
        let conn = UUID()
        let scope = TableScope(connectionId: conn, database: "db", schema: "public", table: "t")
        #expect(PreferenceKeys.columnDisplayFormats(scope).name.hasPrefix("com.TablePro."))
        #expect(PreferenceKeys.recentTables(connectionId: conn).name.hasPrefix("com.TablePro."))
    }
}
