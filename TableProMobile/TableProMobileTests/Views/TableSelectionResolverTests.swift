@testable import TableProMobile
@testable import TableProModels
import Testing

@Suite("Table selection resolver")
struct TableSelectionResolverTests {
    private static func table(_ name: String) -> TableInfo {
        TableInfo(name: name, type: .table)
    }

    private static let catalog = [table("albums"), table("artists"), table("tracks")]

    @Test("A pending name resolves to the table it names")
    func pendingNameResolves() throws {
        let resolved = try #require(TableSelectionResolver.resolve(pendingName: "artists", in: Self.catalog))
        #expect(resolved.name == "artists")
    }

    @Test("No pending name selects nothing")
    func noPendingNameSelectsNothing() {
        #expect(TableSelectionResolver.resolve(pendingName: nil, in: Self.catalog) == nil)
    }

    @Test("A name no table carries selects nothing, so the pending name can resolve once tables load")
    func unknownNameSelectsNothing() {
        #expect(TableSelectionResolver.resolve(pendingName: "invoices", in: Self.catalog) == nil)
        #expect(TableSelectionResolver.resolve(pendingName: "albums", in: []) == nil)
    }

    @Test("A selection the catalog still carries is kept")
    func liveSelectionIsKept() throws {
        let selection = Self.catalog[1]
        let kept = try #require(TableSelectionResolver.keeping(selection, in: Self.catalog))
        #expect(kept == selection)
    }

    @Test("A selection the catalog dropped is cleared rather than left pointing at a table that is gone")
    func staleSelectionIsCleared() {
        let dropped = Self.table("invoices")
        #expect(TableSelectionResolver.keeping(dropped, in: Self.catalog) == nil)
        #expect(TableSelectionResolver.keeping(Self.catalog[0], in: []) == nil)
    }

    @Test("Keeping nothing stays nothing")
    func noSelectionStaysEmpty() {
        #expect(TableSelectionResolver.keeping(nil, in: Self.catalog) == nil)
    }
}
