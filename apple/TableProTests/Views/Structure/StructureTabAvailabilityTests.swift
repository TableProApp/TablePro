//
//  StructureTabAvailabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct StructureTabAvailabilityTests {
    private static let legacyMySQL = StructureServerSupport(
        unsupportedColumnFields: [],
        unsupportedIndexTypes: [],
        checkConstraintRefusal: "Check constraints need MySQL 8.0.16 or later."
    )

    @Test("A MySQL server that discards a CHECK clause is not offered the tab")
    func legacyServerHidesConstraints() {
        let tabs = StructureTabAvailability.tabs(for: .mysql, serverSupport: Self.legacyMySQL)
        #expect(!tabs.contains(.checkConstraints))
        #expect(tabs.contains(.columns))
        #expect(tabs.contains(.indexes))
        #expect(tabs.contains(.foreignKeys))
        #expect(tabs.contains(.ddl))
    }

    @Test("A server that keeps them is offered the tab, on every engine that has them")
    func modernServerShowsConstraints() {
        #expect(StructureTabAvailability.tabs(for: .mysql, serverSupport: .unrestricted)
            .contains(.checkConstraints))
        #expect(StructureTabAvailability.tabs(for: .postgresql, serverSupport: .unrestricted)
            .contains(.checkConstraints))
    }

    @Test("An engine with no check constraints at all stays hidden either way")
    func engineWithoutChecksStaysHidden() {
        for support in [StructureServerSupport.unrestricted, Self.legacyMySQL] {
            let tabs = StructureTabAvailability.tabs(for: .redis, serverSupport: support)
            #expect(!tabs.contains(.checkConstraints))
        }
    }

    // The gate is the driver's statement probe for the object, so any engine whose driver answers gets the tab.
    @Test("Options follows the driver's answer, not the engine type")
    func optionsFollowsTheDriver() {
        #expect(StructureTabAvailability.tabs(for: .postgresql, serverSupport: .unrestricted, offersTableOptions: true)
            .contains(.options))
        #expect(!StructureTabAvailability.tabs(for: .mysql, serverSupport: .unrestricted, offersTableOptions: false)
            .contains(.options))
        #expect(!StructureTabAvailability.tabs(for: .mysql, serverSupport: .unrestricted).contains(.options))
    }

    @Test("Options sits after the editable tabs and before DDL")
    func optionsSitsBeforeDDL() throws {
        let tabs = StructureTabAvailability.tabs(for: .mysql, serverSupport: .unrestricted, offersTableOptions: true)
        let options = try #require(tabs.firstIndex(of: .options))
        let ddl = try #require(tabs.firstIndex(of: .ddl))
        let columns = try #require(tabs.firstIndex(of: .columns))
        #expect(columns < options)
        #expect(options < ddl)
    }

    @Test("Parts is ClickHouse only, and the server refusal does not reach it")
    func partsIsClickHouseOnly() {
        #expect(StructureTabAvailability.tabs(for: .clickhouse, serverSupport: .unrestricted).contains(.parts))
        #expect(!StructureTabAvailability.tabs(for: .mysql, serverSupport: .unrestricted).contains(.parts))
        #expect(StructureTabAvailability.tabs(for: .clickhouse, serverSupport: Self.legacyMySQL).contains(.parts))
    }
}
