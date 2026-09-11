@testable import TablePro
import Testing

@Suite("MetadataLoadState")
struct MetadataLoadStateTests {
    @Test("value returns the payload only for loaded")
    func valueOnlyWhenLoaded() {
        #expect(MetadataLoadState<[String]>.idle.value == nil)
        #expect(MetadataLoadState<[String]>.loading.value == nil)
        #expect(MetadataLoadState<[String]>.failed("boom").value == nil)
        #expect(MetadataLoadState<[String]>.loaded(["a", "b"]).value == ["a", "b"])
    }

    /// A refresh that entered loading over rows it already had blanked the sidebar for the length of
    /// the round trip, which is the rule `SchemaService.runLoad` broke once already (#1916).
    @Test("Entering a load keeps loaded rows and starts loading otherwise")
    func enteringLoadKeepsLoadedRows() {
        #expect(MetadataLoadState<[String]>.loaded(["a"]).enteringLoad == .loaded(["a"]))
        #expect(MetadataLoadState<[String]>.idle.enteringLoad == .loading)
        #expect(MetadataLoadState<[String]>.failed("boom").enteringLoad == .loading)
        #expect(MetadataLoadState<[String]>.loading.enteringLoad == .loading)
    }

    @Test("A fetched list replaces whatever was there")
    func fetchedReplaces() {
        let fetched = MetadataFetchOutcome<[String]>.fetched(["b"])
        #expect(MetadataLoadState<[String]>.loaded(["a"]).settled(by: fetched, discardingValue: false) == .loaded(["b"]))
        #expect(MetadataLoadState<[String]>.loading.settled(by: fetched, discardingValue: true) == .loaded(["b"]))
    }

    @Test("A failure keeps loaded rows, and reports itself when there were none")
    func failureKeepsLoadedRows() {
        let failed = MetadataFetchOutcome<[String]>.failed("boom")
        #expect(MetadataLoadState<[String]>.loaded(["a"]).settled(by: failed, discardingValue: false) == .loaded(["a"]))
        #expect(MetadataLoadState<[String]>.loading.settled(by: failed, discardingValue: false) == .failed("boom"))
    }

    /// Rows fetched from the database being left do not describe the one being entered, so a failed
    /// fetch for the new scope says so rather than showing the old scope's rows under it.
    @Test("A failure after a scope change reports itself over the old scope's rows")
    func failureAfterScopeChangeDiscards() {
        let failed = MetadataFetchOutcome<[String]>.failed("boom")
        #expect(MetadataLoadState<[String]>.loaded(["a"]).settled(by: failed, discardingValue: true) == .failed("boom"))
    }

    @Test("A cancelled fetch never leaves a spinner behind")
    func cancelledFetchClearsItsSpinner() {
        let cancelled = MetadataFetchOutcome<[String]>.cancelled
        #expect(MetadataLoadState<[String]>.loading.settled(by: cancelled, discardingValue: false) == .idle)
        #expect(MetadataLoadState<[String]>.loaded(["a"]).settled(by: cancelled, discardingValue: false) == .loaded(["a"]))
        #expect(MetadataLoadState<[String]>.loaded(["a"]).settled(by: cancelled, discardingValue: true) == .idle)
    }
}
