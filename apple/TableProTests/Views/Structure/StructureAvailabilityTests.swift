//
//  StructureAvailabilityTests.swift
//  TableProTests
//
//  Which sections the Definition page lists and which panes the Structure view offers.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct StructureAvailabilityTests {
    private static let legacyMySQL = StructureServerSupport(
        unsupportedColumnFields: [],
        unsupportedIndexTypes: [],
        checkConstraintRefusal: "Check constraints need MySQL 8.0.16 or later."
    )

    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor(
        _ type: DatabaseType,
        support: StructureServerSupport = .unrestricted
    ) -> StructureDefinitionEditor {
        let editor = StructureDefinitionEditor(
            manager: StructureChangeManager(),
            context: .existingTable(
                connection: TestFixtures.makeConnection(type: type),
                databaseName: "db",
                schemaName: nil,
                tableName: "t",
                objectKind: .table,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.serverSupport = support
        return editor
    }

    private func makeSession(_ type: DatabaseType) -> StructureEditingSession {
        StructureEditingSession(
            identity: "db.t",
            connection: TestFixtures.makeConnection(database: "db", type: type),
            databaseName: "db",
            schemaName: nil,
            tableName: "t"
        )
    }

    // MARK: - Sections

    @Test("A MySQL server that discards a CHECK clause is not offered the section")
    func legacyServerHidesConstraints() {
        let editor = makeEditor(.mysql, support: Self.legacyMySQL)
        #expect(!editor.offers(.checkConstraints))
        #expect(editor.sections == [.columns, .indexes, .foreignKeys])
    }

    @Test("A server that keeps them is offered the section, on every engine that has them")
    func modernServerShowsConstraints() {
        #expect(makeEditor(.mysql).offers(.checkConstraints))
        #expect(makeEditor(.postgresql).offers(.checkConstraints))
    }

    @Test("An engine with no check constraints at all leaves the section out either way")
    func engineWithoutChecksStaysHidden() {
        for support in [StructureServerSupport.unrestricted, Self.legacyMySQL] {
            #expect(!makeEditor(.redis, support: support).offers(.checkConstraints))
        }
    }

    @Test("Foreign Keys follows the engine")
    func foreignKeysFollowTheEngine() {
        #expect(makeEditor(.postgresql).offers(.foreignKeys))
        #expect(!makeEditor(.clickhouse).offers(.foreignKeys))
    }

    @Test("Columns and Indexes are listed on every engine, first and in that order")
    func columnsAndIndexesEverywhere() {
        for type in [DatabaseType.mysql, .postgresql, .sqlite, .redis, .clickhouse] {
            let sections = makeEditor(type).sections
            #expect(Array(sections.prefix(2)) == [.columns, .indexes], "\(type.rawValue)")
        }
        #expect(makeEditor(.postgresql).sections == [.columns, .indexes, .foreignKeys, .checkConstraints])
    }

    @Test("A server that withdraws check constraints later takes the section off the page")
    func withdrawingSupportUpdatesTheSections() {
        let editor = makeEditor(.mysql)
        #expect(editor.sections.contains(.checkConstraints))

        editor.serverSupport = Self.legacyMySQL

        #expect(!editor.sections.contains(.checkConstraints))
    }

    // MARK: - Panes

    @Test("Definition and DDL are offered on every engine, Definition first")
    func definitionAndDDLEverywhere() {
        for type in [DatabaseType.mysql, .postgresql, .redis, .clickhouse] {
            let panes = makeSession(type).availablePanes
            #expect(panes.first == .definition, "\(type.rawValue)")
            #expect(panes.contains(.ddl), "\(type.rawValue)")
        }
    }

    @Test("Triggers follows the engine")
    func triggersFollowTheEngine() {
        #expect(makeSession(.mysql).availablePanes.contains(.triggers))
        #expect(makeSession(.postgresql).availablePanes.contains(.triggers))
        #expect(!makeSession(.redis).availablePanes.contains(.triggers))
    }

    @Test("Parts is ClickHouse only, and the server refusal does not reach it")
    func partsIsClickHouseOnly() {
        let clickhouse = makeSession(.clickhouse)
        #expect(clickhouse.availablePanes.contains(.parts))
        #expect(!makeSession(.mysql).availablePanes.contains(.parts))

        clickhouse.serverSupport = Self.legacyMySQL
        #expect(clickhouse.availablePanes.contains(.parts))
    }

    @Test("Panes keep one order: Definition, Triggers, DDL, Parts")
    func panesKeepTheirOrder() {
        #expect(makeSession(.mysql).availablePanes == [.definition, .triggers, .ddl])
        #expect(makeSession(.clickhouse).availablePanes == [.definition, .ddl, .parts])
    }
}
