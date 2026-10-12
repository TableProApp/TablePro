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

    @Test("Parts is ClickHouse only, and the server refusal does not reach it")
    func partsIsClickHouseOnly() {
        #expect(StructureTabAvailability.tabs(for: .clickhouse, serverSupport: .unrestricted).contains(.parts))
        #expect(!StructureTabAvailability.tabs(for: .mysql, serverSupport: .unrestricted).contains(.parts))
        #expect(StructureTabAvailability.tabs(for: .clickhouse, serverSupport: Self.legacyMySQL).contains(.parts))
    }
}
