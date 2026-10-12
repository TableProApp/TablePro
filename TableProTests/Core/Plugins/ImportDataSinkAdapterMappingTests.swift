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
    private func adapter(mapping: [String: String], sourceFields: Set<String> = []) -> ImportDataSinkAdapter {
        ImportDataSinkAdapter(
            driver: MockDatabaseDriver(),
            databaseType: .mysql,
            targetTable: "people",
            columnMapping: mapping,
            sourceFields: sourceFields
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

    /// A spelling the mapping was not made from, such as a JSON key cased differently in a row past
    /// the sample, still reaches the one mapped field it matches ignoring case.
    @Test("Field matching ignores case")
    func fieldMatchingIgnoresCase() async throws {
        let sink = adapter(mapping: ["Name": "name"])
        try await sink.insertRow(["NAME": .text("Ada")])
    }

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

    @Test("A field the sheet listed and the user skipped never folds onto its twin's column")
    func skippedFieldNeverFolds() {
        let sink = adapter(mapping: ["Email": "email"], sourceFields: ["Email", "email"])

        let (columns, _) = sink.mappedColumnsAndValues(["email": .text("home")])

        #expect(columns.isEmpty)
    }

    @Test("A new spelling of two listed fields that differ only by case reaches neither, mapped or skipped")
    func newSpellingOfListedCaseTwinsDoesNotFold() {
        let sink = adapter(mapping: ["Email": "email"], sourceFields: ["Email", "email"])

        let (columns, _) = sink.mappedColumnsAndValues(["EMAIL": .text("x"), "id": .text("1")])

        #expect(columns.isEmpty)
    }

    @Test("A new spelling of one listed field still reaches its column")
    func newSpellingOfOneListedFieldFolds() {
        let sink = adapter(mapping: ["Email": "email"], sourceFields: ["Email"])

        let (columns, values) = sink.mappedColumnsAndValues(["EMAIL": .text("x")])

        #expect(columns == ["email"])
        #expect(values == [.text("x")])
    }

    @Test("An unknown spelling beside a skipped field of the same name reaches no column")
    func unknownSpellingBesideASkippedTwinDoesNotFold() {
        let sink = adapter(mapping: ["Name": "name"], sourceFields: ["Name", "NAME"])

        let (columns, _) = sink.mappedColumnsAndValues(["NAME": .text("skipped"), "name": .text("unknown")])

        #expect(columns.isEmpty)
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

    /// A session connection can already hold the user's own transaction, as a database kept open
    /// for its rail entry does. Opening one there joined it, and the import's COMMIT then committed
    /// the user's pending work with it.
    @Test("An import into a session holding the user's transaction neither opens nor commits one")
    func importJoinsTheUsersTransaction() async throws {
        let driver = MockDatabaseDriver()
        driver.sessionTransactionStateToReturn = .inTransaction
        let sink = ImportDataSinkAdapter(driver: driver, databaseType: .mysql, targetTable: "people")

        try await sink.beginTransaction()
        try await sink.commitTransaction()

        #expect(driver.beginTransactionCallCount == 0)
        #expect(driver.commitTransactionCallCount == 0)
    }

    @Test("An import into an idle session opens and commits its own transaction")
    func importOwnsItsTransactionOnAnIdleSession() async throws {
        let driver = MockDatabaseDriver()
        driver.sessionTransactionStateToReturn = .idle
        let sink = ImportDataSinkAdapter(driver: driver, databaseType: .mysql, targetTable: "people")

        try await sink.beginTransaction()
        try await sink.commitTransaction()

        #expect(driver.beginTransactionCallCount == 1)
        #expect(driver.commitTransactionCallCount == 1)
    }
}
