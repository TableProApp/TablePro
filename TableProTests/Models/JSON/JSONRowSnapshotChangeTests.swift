//
//  JSONRowSnapshotChangeTests.swift
//  TableProTests
//
//  What counts as a change to the row the JSON tab is showing. A hand-written token over the
//  parts that seemed to matter read a late foreign key fetch as no change, and read a rerun that
//  moved a row's values as no reason to drop the rows fetched for its keys.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("JSONRowSnapshot change detection")
struct JSONRowSnapshotChangeTests {
    private let reference = JSONForeignKeyRef(
        column: "ArtistId",
        referencedTable: "Artist",
        referencedSchema: nil,
        referencedColumn: "ArtistId"
    )

    private func snapshot(
        rowIdentity: String = "tab\u{001F}existing(0)",
        values: [PluginCellValue] = [.text("1"), .text("2")],
        columnTypes: [ColumnType] = [.integer(rawType: "INT"), .integer(rawType: "INT")],
        foreignKeys: [String: JSONForeignKeyRef] = [:]
    ) -> JSONRowSnapshot {
        JSONRowSnapshot(
            rowIdentity: rowIdentity,
            columns: ["AlbumId", "ArtistId"],
            columnTypes: columnTypes,
            values: values,
            foreignKeys: foreignKeys,
            connectionId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(),
            databaseType: .sqlite
        )
    }

    @Test("Foreign keys arriving after the row is on screen is a change")
    func foreignKeyMetadataIsAChange() {
        #expect(snapshot() != snapshot(foreignKeys: ["ArtistId": reference]))
    }

    @Test("Column types arriving after the row is on screen is a change")
    func columnTypesAreAChange() {
        #expect(snapshot() != snapshot(columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]))
    }

    @Test("The same row with a different value is a change")
    func movedValuesAreAChange() {
        #expect(snapshot() != snapshot(values: [.text("1"), .text("3")]))
    }

    @Test("The same row unchanged is not a change")
    func identicalSnapshotsMatch() {
        #expect(snapshot() == snapshot())
    }

    @Test("A rerun keeps a row's identity, so identity alone cannot answer the question")
    func identityOutlivesTheValues() {
        let before = snapshot(values: [.text("1"), .text("1")])
        let after = snapshot(values: [.text("1"), .text("2")])
        #expect(before.rowIdentity == after.rowIdentity)
        #expect(before != after)
    }
}
