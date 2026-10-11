import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("ConnectionFormViewModel DuckDB")
struct ConnectionFormViewModelDuckDBTests {
    @Test("DuckDB is a file-based type")
    func isFileBased() {
        let vm = ConnectionFormViewModel()
        vm.type = .duckdb
        #expect(vm.isFileBased)
    }

    @Test("in-memory mode sets the database to the in-memory sentinel and allows saving")
    func inMemoryEnablesSave() {
        let vm = ConnectionFormViewModel()
        vm.type = .duckdb
        vm.duckDBInMemory = true

        #expect(vm.database == LocalDatabaseLocation.inMemoryPath)
        #expect(vm.canSave)
        #expect(vm.selectedFileURL == nil)
    }

    @Test("disabling in-memory clears the sentinel path")
    func disablingInMemoryClearsPath() {
        let vm = ConnectionFormViewModel()
        vm.type = .duckdb
        vm.duckDBInMemory = true
        vm.duckDBInMemory = false

        #expect(vm.database.isEmpty)
        #expect(!vm.canSave)
    }

    @Test("create new database uses the .duckdb extension")
    func createNewUsesDuckDBExtension() throws {
        let fixture = try AppStateFixture()
        let vm = fixture.makeFormViewModel()
        vm.type = .duckdb
        vm.newDatabaseName = "analytics"
        vm.createNewDatabase()

        #expect(vm.database == fixture.documentsFile("analytics.duckdb").path)
        #expect(vm.canSave)
    }

    @Test("A DuckDB file picked inside Documents is used in place, with no bookmark")
    func documentsPickNeedsNoBookmark() throws {
        let fixture = try AppStateFixture()
        let file = fixture.documentsFile("cube.duckdb")
        try Data().write(to: file)
        let vm = fixture.makeFormViewModel()
        vm.type = .duckdb

        vm.handleDuckDBFilePicker(.success([file]))

        #expect(vm.database == file.path)
        #expect(vm.pendingFile == .documentsFile)
    }

    @Test("An in-memory DuckDB connection opens the form in in-memory mode")
    func inMemoryConnectionHydrates() {
        let stored = DatabaseConnection(type: .duckdb, database: LocalDatabaseLocation.inMemoryPath)
        let vm = ConnectionFormViewModel(editing: stored)

        #expect(vm.duckDBInMemory)
        #expect(vm.selectedFileURL == nil)
        #expect(vm.database == LocalDatabaseLocation.inMemoryPath)
    }

    @Test("switching type away from DuckDB resets in-memory state")
    func switchingTypeResets() {
        let vm = ConnectionFormViewModel()
        vm.type = .duckdb
        vm.duckDBInMemory = true
        vm.type = .mysql

        #expect(!vm.duckDBInMemory)
        #expect(vm.database.isEmpty)
    }
}
