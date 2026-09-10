//
//  ExportProfileStorageTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Export profiles")
struct ExportProfileStorageTests {

    private func databases() -> [ExportDatabaseItem] {
        [
            ExportDatabaseItem(name: "app", objects: [
                ExportObjectItem(name: "users", kind: .table, isSelected: true, optionValues: [true, false, true]),
                ExportObjectItem(name: "posts", kind: .table, isSelected: false, optionValues: [true, true, true]),
                ExportObjectItem(name: "recalc", kind: .routine, isSelected: true, optionValues: [true, true, false])
            ])
        ]
    }

    @Test("A profile captures only the selected objects")
    func profileCapturesSelection() {
        let profile = ExportProfileStorage.makeProfile(
            name: "Nightly", formatId: "sql", databases: databases())
        #expect(profile.entries.count == 2)
        #expect(Set(profile.entries.map(\.name)) == ["users", "recalc"])
        #expect(profile.formatId == "sql")
    }

    @Test("A profile carries each object's options and row scope")
    func profileCarriesOptionsAndScope() {
        var items = databases()
        items[0].objects[0].rowScope = PluginExportRowScope(filter: "active", rowLimit: 50)
        let profile = ExportProfileStorage.makeProfile(name: "N", formatId: "sql", databases: items)
        let users = try? #require(profile.entries.first { $0.name == "users" })
        #expect(users?.optionValues == [true, false, true])
        #expect(users?.rowScope.rowLimit == 50)
        #expect(users?.rowScope.sanitizedFilter == "active")
    }

    /// A routine and a table can share a name, so the key has to carry the kind or applying a
    /// profile would tick the wrong row.
    @Test("A profile entry is keyed by container, kind and name")
    func entryKeyIncludesKind() {
        let table = ExportProfile.Entry(
            container: "app", name: "users", kind: .table, optionValues: [], rowScope: .unrestricted)
        let routine = ExportProfile.Entry(
            container: "app", name: "users", kind: .routine, optionValues: [], rowScope: .unrestricted)
        #expect(table.key != routine.key)
    }

    @Test("Applying a profile restores its selection and clears everything else")
    func applyRestoresSelection() {
        let profile = ExportProfileStorage.makeProfile(
            name: "N", formatId: "sql", databases: databases())
        var cleared = databases()
        for index in cleared[0].objects.indices {
            cleared[0].objects[index].isSelected = false
            cleared[0].objects[index].optionValues = []
        }
        let applied = ExportProfileStorage.apply(profile, to: cleared)
        #expect(applied[0].objects.filter(\.isSelected).map(\.name).sorted() == ["recalc", "users"])
        #expect(applied[0].objects.first { $0.name == "users" }?.optionValues == [true, false, true])
    }

    /// Applying twice must give the same selection both times, so a row the profile does not name
    /// is deselected rather than left ticked from whatever was there before.
    @Test("Applying a profile is idempotent")
    func applyIsIdempotent() {
        let profile = ExportProfileStorage.makeProfile(
            name: "N", formatId: "sql", databases: databases())
        var items = databases()
        items[0].objects[1].isSelected = true
        let once = ExportProfileStorage.apply(profile, to: items)
        let twice = ExportProfileStorage.apply(profile, to: once)
        #expect(once.map { $0.objects.map(\.isSelected) } == twice.map { $0.objects.map(\.isSelected) })
        #expect(once[0].objects[1].isSelected == false)
    }

    @Test("An object the database no longer holds is counted as missing, not resurrected")
    func missingObjectsAreCounted() {
        let profile = ExportProfileStorage.makeProfile(
            name: "N", formatId: "sql", databases: databases())
        var shrunk = databases()
        shrunk[0].objects.removeAll { $0.name == "recalc" }
        #expect(ExportProfileStorage.matchCount(profile, in: shrunk) == 1)

        let applied = ExportProfileStorage.apply(profile, to: shrunk)
        #expect(applied[0].objects.count == 2)
        #expect(applied[0].objects.filter(\.isSelected).map(\.name) == ["users"])
    }

    @MainActor @Test("Profiles round trip through the store")
    func profilesRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let connectionId = UUID()
        let store = ExportProfileStorage(directory: directory)
        let profile = ExportProfileStorage.makeProfile(
            name: "Nightly", formatId: "sql", databases: databases())

        store.save(profile, for: connectionId)
        let reloaded = ExportProfileStorage(directory: directory).profiles(for: connectionId)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.name == "Nightly")
        #expect(reloaded.first?.entries.count == 2)
    }

    /// Saving under a name that already exists replaces it, so the picker never shows two rows
    /// with the same label.
    @MainActor @Test("Saving under an existing name replaces it")
    func savingReplacesByName() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ExportProfileStorage(directory: directory)
        let connectionId = UUID()
        store.save(
            ExportProfileStorage.makeProfile(name: "N", formatId: "sql", databases: databases()),
            for: connectionId)

        var narrowed = databases()
        narrowed[0].objects[2].isSelected = false
        store.save(
            ExportProfileStorage.makeProfile(name: "N", formatId: "csv", databases: narrowed),
            for: connectionId)

        let profiles = store.profiles(for: connectionId)
        #expect(profiles.count == 1)
        #expect(profiles[0].formatId == "csv")
        #expect(profiles[0].entries.count == 1)
    }

    @MainActor @Test("Deleting the last profile removes the file rather than leaving an empty one")
    func deletingLastProfileRemovesFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ExportProfileStorage(directory: directory)
        let connectionId = UUID()
        let profile = ExportProfileStorage.makeProfile(
            name: "N", formatId: "sql", databases: databases())
        store.save(profile, for: connectionId)
        store.delete(id: profile.id, for: connectionId)

        #expect(store.profiles(for: connectionId).isEmpty)
        let file = directory.appendingPathComponent("\(connectionId.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor @Test("A connection with no saved profiles reads back empty")
    func unknownConnectionIsEmpty() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ExportProfileStorage(directory: directory).profiles(for: UUID()).isEmpty)
    }
}

@Suite("Import error report")
struct ImportErrorReportTests {

    private let errors = [
        PluginImportResult.ImportStatementError(
            statement: "row 12", line: 12, errorMessage: "duplicate key value"),
        PluginImportResult.ImportStatementError(
            statement: "row 40", line: 40, errorMessage: "null value in column \"name\"")
    ]

    @Test("The report names the source, the target and the skipped count")
    func reportHeader() {
        let csv = ImportErrorReport.makeCSV(
            sourceFileName: "users.csv", targetTable: "users", errors: errors, totalSkipped: 2)
        #expect(csv.contains("# Source: users.csv"))
        #expect(csv.contains("# Target: users"))
        #expect(csv.contains("# Skipped rows: 2"))
        #expect(csv.contains("line,statement,error"))
    }

    @Test("Each skipped row appears with its line and the server's own message")
    func reportRows() {
        let csv = ImportErrorReport.makeCSV(
            sourceFileName: "users.csv", targetTable: nil, errors: errors, totalSkipped: 2)
        #expect(csv.contains("12,row 12,duplicate key value"))
        #expect(csv.contains("40,row 40,\"null value in column \"\"name\"\"\""))
    }

    /// A message holding a comma or a newline would otherwise break the column count and every
    /// spreadsheet would read the rest of the file shifted.
    @Test("A message with a comma or a newline stays inside its field")
    func messagesAreQuoted() {
        let awkward = [PluginImportResult.ImportStatementError(
            statement: "row 1", line: 1, errorMessage: "bad value, at\nline 2")]
        let csv = ImportErrorReport.makeCSV(
            sourceFileName: "a.csv", targetTable: nil, errors: awkward, totalSkipped: 1)
        let dataLines = csv.split(separator: "\n").filter { !$0.hasPrefix("#") && $0 != "line,statement,error" }
        #expect(dataLines.count == 1)
        #expect(dataLines[0] == "1,row 1,\"bad value, at line 2\"")
    }

    @Test("A count larger than the listed errors says how many were left out")
    func truncationIsStated() {
        let csv = ImportErrorReport.makeCSV(
            sourceFileName: "a.csv", targetTable: nil, errors: errors, totalSkipped: 500)
        #expect(csv.contains("# Skipped rows: 500"))
        #expect(csv.contains("# Listed below: 2"))
    }

    @Test("The default report name sits beside the file it came from")
    func defaultFileName() {
        #expect(ImportErrorReport.defaultFileName(forSource: "users.csv") == "users-errors.csv")
        #expect(ImportErrorReport.defaultFileName(forSource: "dump.sql.gz") == "dump.sql-errors.csv")
        #expect(ImportErrorReport.defaultFileName(forSource: "") == "import-errors.csv")
    }
}
