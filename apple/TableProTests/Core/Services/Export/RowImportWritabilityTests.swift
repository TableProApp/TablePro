//
//  RowImportWritabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class RowFormatStub: ImportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Row Format"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Writes rows into a table"
    static let formatId = "row-format"
    static let formatDisplayName = "Rows"
    static let acceptedFileExtensions = ["rows"]
    static let iconName = "doc"
    static let requiresTargetTable = true

    required init() {}

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        PluginImportResult(executedStatements: 0, executionTime: 0)
    }
}

private final class StatementFormatStub: ImportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Statement Format"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Runs statements"
    static let formatId = "statement-format"
    static let formatDisplayName = "Statements"
    static let acceptedFileExtensions = ["statements"]
    static let iconName = "doc"

    required init() {}

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        PluginImportResult(executedStatements: 0, executionTime: 0)
    }
}

@MainActor
struct RowImportWritabilityTests {
    private static let offersCSVAndSQL = ImportFormatLookup(
        supportsImport: { _ in true },
        offeredFormats: { _ in
            [ImportFormatOption(id: "csv", name: "CSV"), ImportFormatOption(id: "sql", name: "SQL")]
        },
        requiresTargetTable: { $0 == "csv" }
    )

    private func check(_ formatId: String, into databaseType: DatabaseType) -> RowImportRefusal? {
        RowImportEligibility.refusal(
            formatId: formatId,
            databaseType: databaseType,
            connectionName: "Catalog",
            safeModeLevel: .silent,
            isPresentingSheet: false,
            lookup: Self.offersCSVAndSQL
        )
    }

    @Test("A row file into MongoDB is refused before it is read, with a reason the user can act on")
    func mongoDBRefusesRowFiles() {
        let refusal = check("csv", into: .mongodb)

        #expect(refusal == .rowsNotWritable(.mongodb))
        #expect(refusal?.localizedDescription == String(
            format: String(localized: "%@ cannot take rows from a file."), "MongoDB"
        ))
    }

    @Test("An engine the sink can write rows into is not refused")
    func sqlEngineTakesRowFiles() {
        #expect(check("csv", into: .postgresql) == nil)
    }

    @Test("A statement format is judged by its offer, not by whether rows can be written")
    func statementFormatSkipsTheRowCheck() {
        #expect(check("sql", into: .mongodb) == .formatNotOffered(formatId: "sql"))
    }

    @Test("The refusal asks the same question the sink asks before its first batch")
    func refusalFollowsTheSink() {
        #expect(!ImportDataSinkAdapter.canWriteRows(into: .mongodb))
        #expect(ImportDataSinkAdapter.canWriteRows(into: .postgresql))
    }

    @Test("A row format is not offered to an engine the sink cannot write rows into")
    func rowFormatIsNotOfferedWhereRowsCannotBeWritten() {
        let mongoWritesRows = ImportDataSinkAdapter.canWriteRows(into: .mongodb)
        let postgresWritesRows = ImportDataSinkAdapter.canWriteRows(into: .postgresql)

        #expect(!PluginManager.offers(RowFormatStub.self, to: .mongodb, writesRows: mongoWritesRows))
        #expect(PluginManager.offers(RowFormatStub.self, to: .postgresql, writesRows: postgresWritesRows))
        #expect(PluginManager.offers(StatementFormatStub.self, to: .mongodb, writesRows: mongoWritesRows))
    }
}
