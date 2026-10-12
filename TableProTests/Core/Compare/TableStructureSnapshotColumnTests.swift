//
//  TableStructureSnapshotColumnTests.swift
//  TableProTests
//
//  The column read Copy To, Duplicate Table and Compare build their DDL from.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableStructureSnapshotColumnTests {
    @Test("A column read keeps the server's spellings all the way to the CREATE TABLE definition")
    func snapshotCarriesDDLSpellingToCreateTableDefinition() {
        let shape = PluginColumnInfo(
            name: "shape",
            dataType: "geometry",
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "public.geometry(Point,4326)",
            ddlDefault: nil,
            ddlGenerationExpression: nil
        )
        let status = PluginColumnInfo(
            name: "status",
            dataType: "ENUM",
            defaultValue: "'new'::order_status",
            allowedValues: ["new", "paid"],
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: "app.order_status",
            ddlDefault: "'new'::app.order_status",
            ddlGenerationExpression: nil
        )
        let snapshot = TableStructureSnapshot.from(
            table: PluginTableInfo(name: "places", schema: "public", comment: nil),
            columns: [shape, status],
            indexes: [],
            foreignKeys: []
        )
        let definitions = snapshot.columns.map { $0.toPlugin() }
        #expect(definitions.map(\.ddlSpelling) == ["public.geometry(Point,4326)", "app.order_status"])
        #expect(definitions.map(\.ddlDefault) == [nil, "'new'::app.order_status"])
        #expect(definitions.map(\.dataType) == ["geometry", "ENUM"])
        #expect(definitions.map(\.defaultValue) == [nil, "'new'::order_status"])
    }

    @Test("A driver that reports no spelling leaves the definition to its declared type")
    func snapshotWithoutDDLSpellingKeepsNil() {
        let snapshot = TableStructureSnapshot.from(
            table: PluginTableInfo(name: "orders", comment: nil),
            columns: [PluginColumnInfo(name: "id", dataType: "INT")],
            indexes: [],
            foreignKeys: []
        )
        #expect(snapshot.columns.first?.ddlSpelling == nil)
        #expect(snapshot.columns.first?.toPlugin().ddlSpelling == nil)
    }
}
