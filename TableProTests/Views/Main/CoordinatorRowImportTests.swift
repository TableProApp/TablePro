//
//  CoordinatorRowImportTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@Suite("Coordinator row import entry")
@MainActor
struct CoordinatorRowImportTests {
    private final class ErrorRecorder {
        var presented: [(title: String, message: String)] = []
    }

    private func makeCoordinator(
        type: DatabaseType = .postgresql,
        safeModeLevel: SafeModeLevel = .silent,
        lookup: ImportFormatLookup = CoordinatorRowImportTests.importsCSV
    ) -> (MainContentCoordinator, ErrorRecorder) {
        let toolbarState = ConnectionToolbarState()
        toolbarState.safeModeLevel = safeModeLevel
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(name: "Warehouse", type: type),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: toolbarState
        )
        coordinator.importFormatLookup = lookup
        let recorder = ErrorRecorder()
        coordinator.presentError = { title, message, _ in
            recorder.presented.append((title, message))
        }
        return (coordinator, recorder)
    }

    private static let importsCSV = ImportFormatLookup(
        supportsImport: { _ in true },
        offeredFormats: { _ in
            [ImportFormatOption(id: "csv", name: "CSV"), ImportFormatOption(id: "sql", name: "SQL")]
        },
        requiresTargetTable: { $0 == "csv" }
    )

    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("row-import-\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try "id,name\n1,Ada\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func rowImportFormatId(of coordinator: MainContentCoordinator) -> String? {
        guard case .rowImport(let formatId) = coordinator.activeSheet else { return nil }
        return formatId
    }

    @Test("A read-only connection refuses the file and leaves it with the caller")
    func readOnlyRefuses() throws {
        let (coordinator, recorder) = makeCoordinator(safeModeLevel: .readOnly)
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let refusal = coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: true)

        #expect(refusal == .readOnly(connectionName: "Warehouse"))
        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.importFile == nil)
        #expect(recorder.presented.isEmpty)
        #expect(exists(url))
    }

    @Test("An engine that imports nothing refuses with the same alert the Import menu shows")
    func unsupportedEngineRefusesWithAlert() throws {
        var lookup = Self.importsCSV
        lookup.supportsImport = { _ in false }
        let (coordinator, recorder) = makeCoordinator(type: .redis, lookup: lookup)
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let refusal = coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: true)

        #expect(refusal == .importNotSupported(.redis))
        #expect(coordinator.activeSheet == nil)
        #expect(recorder.presented.map { $0.title } == [String(localized: "Import Not Supported")])
        #expect(recorder.presented.first?.message == refusal?.localizedDescription)
        #expect(exists(url))
    }

    @Test("A format the connection does not offer is refused")
    func unofferedFormatRefuses() throws {
        let (coordinator, recorder) = makeCoordinator()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(coordinator.presentRowImport(of: url, formatId: "xlsx", ownsFile: false) == .formatNotOffered(formatId: "xlsx"))
        #expect(coordinator.activeSheet == nil)
        #expect(recorder.presented.isEmpty)
    }

    @Test("A statement format is not a row import")
    func statementFormatRefuses() throws {
        let (coordinator, _) = makeCoordinator()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(coordinator.presentRowImport(of: url, formatId: "sql", ownsFile: false) == .formatNotOffered(formatId: "sql"))
        #expect(coordinator.activeSheet == nil)
    }

    @Test("A window already showing a sheet is not interrupted")
    func busyWindowRefuses() throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.activeSheet = .exportDialog
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let refusal = coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: true)

        #expect(refusal == .sheetAlreadyPresented(connectionName: "Warehouse"))
        #expect(rowImportFormatId(of: coordinator) == nil)
        #expect(coordinator.importFile == nil)
        #expect(exists(url))
    }

    @Test("An accepted file opens the row import sheet on it")
    func acceptedFileOpensRowImport() throws {
        let (coordinator, _) = makeCoordinator()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(coordinator.rowImportRefusal(formatId: "csv") == nil)
        #expect(coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: false) == nil)

        #expect(rowImportFormatId(of: coordinator) == "csv")
        #expect(coordinator.importFile == ImportFileHandoff(url: url, ownsFile: false))
    }

    @Test("An owned file is deleted when the sheet closes")
    func ownedFileIsDeletedOnDismiss() throws {
        let (coordinator, _) = makeCoordinator()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: true)
        #expect(exists(url))

        coordinator.activeSheet = nil

        #expect(coordinator.importFile == nil)
        #expect(!exists(url))
    }

    @Test("A file the caller keeps survives the sheet closing")
    func borrowedFileSurvivesDismiss() throws {
        let (coordinator, _) = makeCoordinator()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: false)
        coordinator.activeSheet = nil

        #expect(coordinator.importFile == nil)
        #expect(exists(url))
    }

    @Test("Tearing the coordinator down deletes an owned file whose sheet never closed")
    func teardownDeletesOwnedFile() throws {
        let (coordinator, _) = makeCoordinator()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.presentRowImport(of: url, formatId: "csv", ownsFile: true)
        coordinator.teardown()

        #expect(coordinator.importFile == nil)
        #expect(!exists(url))
    }

    @Test("Only the two import sheets carry the import file")
    func importSheetsCarryTheFile() {
        #expect(ActiveSheet.rowImport(formatId: "csv").carriesImportFile)
        #expect(ActiveSheet.importDialog(formatId: "sql").carriesImportFile)
        #expect(!ActiveSheet.exportDialog.carriesImportFile)
        #expect(!ActiveSheet.exportQueryResults.carriesImportFile)
    }

    @Test("Discarding a borrowed handoff never deletes the file")
    func borrowedHandoffDiscardKeepsFile() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        ImportFileHandoff(url: url, ownsFile: false).discard()
        #expect(exists(url))

        ImportFileHandoff(url: url, ownsFile: true).discard()
        #expect(!exists(url))
    }
}
