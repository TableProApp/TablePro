import Foundation
import Testing
import TableProModels
@testable import TableProMobile

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

        #expect(vm.database == DuckDBDriver.inMemoryPath)
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
    func createNewUsesDuckDBExtension() {
        let vm = ConnectionFormViewModel()
        vm.type = .duckdb
        vm.newDatabaseName = "analytics"
        vm.createNewDatabase()

        #expect(vm.database.hasSuffix("analytics.duckdb"))
        #expect(vm.canSave)
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
