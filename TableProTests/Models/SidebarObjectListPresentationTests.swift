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
        hasRoutines: Bool = false,
        hasTriggers: Bool = false,
        hasOutlastedGrace: Bool = true
    ) -> SidebarObjectListPresentation {
        SidebarObjectListPresentation.resolve(
            state: state,
            hasActiveFilter: hasActiveFilter,
            hasAnyMatch: hasAnyMatch,
            hasRoutines: hasRoutines,
            hasTriggers: hasTriggers,
            hasOutlastedGrace: hasOutlastedGrace
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
        /// A schema whose only objects are triggers is not an empty schema.
        #expect(resolve(.loaded([]), hasTriggers: true) == .list)
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

    // MARK: - The grace

    /// The schema of a local database arrives in about 110ms, so the column stays blank rather
    /// than spinning for a tenth of a second.
    @Test("A schema read too young to report leaves the column blank")
    func loadingInsideTheGracePrepares() {
        #expect(resolve(.idle, hasOutlastedGrace: false) == .preparing)
        #expect(resolve(.loading, hasOutlastedGrace: false) == .preparing)
    }

    /// A read that has taken long enough for the user to wonder is exactly what a spinner is for.
    @Test("A schema read that outlasts the grace gets its spinner")
    func loadingPastTheGraceShowsTheSpinner() {
        #expect(resolve(.idle, hasOutlastedGrace: false) != resolve(.idle))
        #expect(resolve(.loading) == .loading)
    }

    /// The grace holds back a wait, never an answer. A refused read has to say so at once, or the
    /// user is left looking at a blank column that gives no reason and offers no Retry.
    @Test("The grace never delays a failure or a finished list")
    func settledStatesIgnoreTheGrace() {
        #expect(resolve(.failed("boom"), hasOutlastedGrace: false) == .failed("boom"))
        #expect(resolve(.loaded([]), hasOutlastedGrace: false) == .empty)
        #expect(resolve(.loaded([table("users")]), hasOutlastedGrace: false) == .list)
    }
}
