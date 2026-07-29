//
//  TableScopeDecodeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableScope decode")
struct TableScopeDecodeTests {
    @Test("Round-trips a full scope through the storage component")
    func roundTrips() {
        let scope = TableScope(connectionId: UUID(), database: "shop", schema: "public", table: "orders")
        #expect(TableScope(storageComponent: scope.storageComponent) == scope)
    }

    @Test("Round-trips with nil database and schema")
    func roundTripsWithNils() {
        let scope = TableScope(connectionId: UUID(), database: nil, schema: nil, table: "t")
        #expect(TableScope(storageComponent: scope.storageComponent) == scope)
    }

    @Test("Round-trips identifiers that contain separators and spaces")
    func roundTripsSpecialCharacters() {
        let scope = TableScope(connectionId: UUID(), database: "my.db", schema: "a b", table: "t.able")
        #expect(TableScope(storageComponent: scope.storageComponent) == scope)
    }

    @Test("displayName joins the present parts")
    func displayName() {
        let scope = TableScope(connectionId: UUID(), database: "shop", schema: nil, table: "orders")
        #expect(scope.displayName == "shop.orders")
    }

    @Test("Rejects a malformed storage component")
    func rejectsMalformed() {
        #expect(TableScope(storageComponent: "not-a-key") == nil)
    }
}
