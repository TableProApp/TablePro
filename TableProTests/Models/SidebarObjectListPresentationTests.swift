import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Sidebar object list presentation")
struct SidebarObjectListPresentationTests {
    private func table(_ name: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: nil)
    }

    private func resolve(
        _ state: SchemaState,
        hasActiveFilter: Bool = false,
        hasAnyMatch: Bool = true,
        hasRoutines: Bool = false
    ) -> SidebarObjectListPresentation {
        SidebarObjectListPresentation.resolve(
            state: state,
            hasActiveFilter: hasActiveFilter,
            hasAnyMatch: hasAnyMatch,
            hasRoutines: hasRoutines
        )
    }

    @Test("A connection whose schema has never loaded is still loading, not empty")
    func idleIsLoadingNotEmpty() {
        #expect(resolve(.idle) == .loading)
    }

    @Test("A load in flight shows the spinner")
    func loadingShowsSpinner() {
        #expect(resolve(.loading) == .loading)
    }

    @Test("A database that really has no objects says so")
    func loadedAndEmptySaysEmpty() {
        #expect(resolve(.loaded([])) == .empty)
    }

    @Test("A database with only routines is not empty")
    func routinesAloneAreNotEmpty() {
        #expect(resolve(.loaded([]), hasRoutines: true) == .list)
    }

    @Test("Loaded objects render the list")
    func loadedRendersList() {
        #expect(resolve(.loaded([table("users")])) == .list)
    }

    @Test("A filter that matches nothing reports no match rather than an empty database")
    func filterWithoutMatchesSaysNoMatch() {
        let presentation = resolve(
            .loaded([table("users")]),
            hasActiveFilter: true,
            hasAnyMatch: false
        )
        #expect(presentation == .noMatch)
    }

    @Test("A filter that matches keeps rendering the list")
    func filterWithMatchesRendersList() {
        let presentation = resolve(
            .loaded([table("users")]),
            hasActiveFilter: true,
            hasAnyMatch: true
        )
        #expect(presentation == .list)
    }

    @Test("A failed load surfaces its message instead of claiming the database is empty")
    func failureSurfacesMessage() {
        #expect(resolve(.failed("boom")) == .failed("boom"))
    }
}
