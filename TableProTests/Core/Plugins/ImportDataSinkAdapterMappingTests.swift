//
//  ImportDataSinkAdapterMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// A row none of whose fields reach a mapped column writes nothing. It used to be dropped in
/// silence and still counted as inserted, so "Import completed" reported more rows than reached the
/// database. Refusing it makes the count honest: Skip and Continue records the row against its
/// line, and the stop modes halt on a mapping that matches nothing.
@MainActor
struct ImportDataSinkAdapterMappingTests {
    private func adapter(mapping: [String: String]) -> ImportDataSinkAdapter {
        ImportDataSinkAdapter(
            driver: MockDatabaseDriver(),
            databaseType: .mysql,
            targetTable: "people",
            columnMapping: mapping
        )
    }

    @Test("A row with no mapped field is refused rather than dropped")
    func unmappedRowIsRefused() async {
        let sink = adapter(mapping: ["name": "name"])
        await #expect(throws: PluginImportError.self) {
            try await sink.insertRow(["unrelated": .text("x")])
        }
    }

    @Test("A batch containing a row with no mapped field is refused")
    func unmappedRowInBatchIsRefused() async {
        let sink = adapter(mapping: ["name": "name"])
        await #expect(throws: PluginImportError.self) {
            try await sink.insertRows([
                ["name": .text("Ada")],
                ["unrelated": .text("x")],
            ])
        }
    }

    @Test("A row whose field maps is accepted")
    func mappedRowIsAccepted() async throws {
        let sink = adapter(mapping: ["name": "name"])
        try await sink.insertRow(["name": .text("Ada")])
    }

    /// The mapping is matched case-insensitively, so a header cased differently to the column still
    /// reaches it rather than being refused.
    @Test("Field matching ignores case")
    func fieldMatchingIgnoresCase() async throws {
        let sink = adapter(mapping: ["Name": "name"])
        try await sink.insertRow(["NAME": .text("Ada")])
    }

    /// Every name used to be folded, so the twin landed on the mapped field's column and the INSERT
    /// named it twice.
    @Test("A field whose twin differing only by case is mapped exactly is left out")
    func caseTwinOfAMappedFieldStaysUnmapped() {
        let sink = adapter(mapping: ["Email": "email"])

        let (columns, values) = sink.mappedColumnsAndValues(["Email": .text("work"), "email": .text("home")])

        #expect(columns == ["email"])
        #expect(values == [.text("work")])
    }

    @Test("Two fields that differ only by case reach their own columns")
    func caseTwinsReachTheirOwnColumns() {
        let sink = adapter(mapping: ["Email": "work_email", "email": "home_email"])

        let (columns, values) = sink.mappedColumnsAndValues(["Email": .text("work"), "email": .text("home")])

        #expect(columns == ["home_email", "work_email"])
        #expect(values == [.text("home"), .text("work")])
    }

    @Test("A third spelling of two mapped fields that differ only by case reaches neither column")
    func ambiguousMappingKeysDoNotFold() {
        let sink = adapter(mapping: ["Email": "work_email", "email": "home_email"])

        let (columns, _) = sink.mappedColumnsAndValues(["EMAIL": .text("x")])

        #expect(columns.isEmpty)
    }

    @Test("Two unknown spellings of one mapped field in a row reach neither column")
    func ambiguousRowKeysDoNotFold() {
        let sink = adapter(mapping: ["Name": "name"])

        let (columns, _) = sink.mappedColumnsAndValues(["NAME": .text("a"), "name": .text("b"), "id": .text("1")])

        #expect(columns.isEmpty)
    }

    /// A row carrying nothing has nothing to lose, so it passes through. Only a row holding values
    /// that reach no column is worth stopping for, and conflating the two would turn an empty
    /// object in an NDJSON file into a failed import.
    @Test("A row with no values at all is not an error")
    func emptyRowIsNotAnError() async throws {
        let sink = adapter(mapping: ["name": "name"])
        try await sink.insertRow([:])
    }

    @Test("An empty row inside a batch is not an error")
    func emptyRowInBatchIsNotAnError() async throws {
        let sink = adapter(mapping: ["name": "name"])
        try await sink.insertRows([
            ["name": .text("Ada")],
            [:],
            ["name": .text("Grace")],
        ])
    }
}
