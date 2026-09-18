//
//  DatabaseSwitcherRefreshTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Database switcher refresh")
@MainActor
struct DatabaseSwitcherRefreshTests {
    private func makeViewModel(currentDatabase: String? = nil) -> DatabaseSwitcherViewModel {
        DatabaseSwitcherViewModel(
            connectionId: UUID(),
            currentDatabase: currentDatabase,
            databaseType: .mysql,
            sidebarState: SharedSidebarState()
        )
    }

    private func metadata(_ names: [String]) -> [DatabaseMetadata] {
        names.map { DatabaseMetadata.minimal(name: $0, isSystem: false) }
    }

    @Test("The first load preselects the current database")
    func firstLoadPreselectsCurrent() {
        let viewModel = makeViewModel(currentDatabase: "chinook")

        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))

        #expect(viewModel.selectedDatabase == "chinook")
    }

    @Test("The first load falls back to the first row when there is no current database")
    func firstLoadFallsBackToFirstRow() {
        let viewModel = makeViewModel()

        viewModel.applyFetched(metadata(["analytics", "chinook"]))

        #expect(viewModel.selectedDatabase == "analytics")
    }

    /// The regression. The slow bulk metadata pass lands after the list is interactive, and it used
    /// to reset the selection to the current database, so the row the user had arrowed to was taken
    /// out from under them.
    @Test("A later fetch keeps the selection the user made")
    func laterFetchKeepsUserSelection() {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))
        viewModel.selectedDatabase = "staging"

        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))

        #expect(viewModel.selectedDatabase == "staging")
    }

    @Test("A selection that no longer exists is replaced")
    func vanishedSelectionIsReplaced() {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))
        viewModel.selectedDatabase = "staging"

        viewModel.applyFetched(metadata(["analytics", "chinook"]))

        #expect(viewModel.selectedDatabase == "chinook")
    }

    @Test("A multiple selection keeps the rows that survived and drops the rest")
    func multipleSelectionIsPruned() {
        let viewModel = makeViewModel()
        viewModel.applyFetched(metadata(["analytics", "chinook", "staging"]))
        viewModel.selectedDatabases = ["analytics", "staging"]

        viewModel.applyFetched(metadata(["analytics", "chinook"]))

        #expect(viewModel.selectedDatabases == ["analytics"])
    }

    /// Preselecting a row the filter hides left `primarySelection` nil, so Return did nothing and
    /// the switcher looked dead.
    @Test("A fetch under an active filter selects a row the filter shows")
    func fetchUnderFilterSelectsAVisibleRow() {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook", "reporting"]))
        viewModel.searchText = "rep"

        viewModel.applyFetched(metadata(["analytics", "chinook", "reporting"]))

        #expect(viewModel.selectedDatabase == "reporting")
        #expect(viewModel.primarySelection == "reporting")
    }

    @Test("A successful fetch clears an error left by an earlier failure")
    func successClearsTheError() {
        let viewModel = makeViewModel()
        viewModel.errorMessage = "Lost connection"

        viewModel.applyFetched(metadata(["analytics"]))

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isLoading == false)
    }

    /// The CLAUDE.md invariant: a refresh never clears the cache it is refreshing. Nothing is
    /// connected here, so the fetch fails, which is exactly the case being guarded.
    @Test("A failed refresh keeps the loaded list and reports no error")
    func failedRefreshKeepsData() async {
        let viewModel = makeViewModel(currentDatabase: "chinook")
        viewModel.applyFetched(metadata(["analytics", "chinook"]))
        viewModel.selectedDatabase = "analytics"

        await viewModel.fetchDatabases()

        #expect(viewModel.databases.map(\.name) == ["analytics", "chinook"])
        #expect(viewModel.selectedDatabase == "analytics")
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isLoading == false)
    }

    @Test("A failed first load reports the error, because there is nothing to fall back on")
    func failedFirstLoadReportsTheError() async {
        let viewModel = makeViewModel()

        await viewModel.fetchDatabases()

        #expect(viewModel.databases.isEmpty)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.isLoading == false)
    }
}
