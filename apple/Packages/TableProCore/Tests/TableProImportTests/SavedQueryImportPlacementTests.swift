import Foundation
import Testing

@testable import TableProImport

struct SavedQueryImportPlacementTests {
    private let scope = UUID()
    private let otherScope = UUID()

    private func folder(_ name: String, scope: UUID? = nil) -> PathComponent {
        PathComponent(name: name, scope: scope, color: nil)
    }

    private func planned(_ name: String, sql: String = "SELECT 1") -> PlannedQuery {
        PlannedQuery(ref: "q1", name: name, sql: sql, keyword: nil, connectionId: nil, folderPath: [])
    }

    @Test("A path every folder of which can hold the query is kept whole")
    func holdablePathIsKept() {
        let path = [folder("Team"), folder("Mine", scope: scope)]

        #expect(SavedQueryImportPlacement.holdableFolderPath(path, for: scope) == path)
    }

    @Test("A global query drops a scoped leaf it cannot sit in")
    func globalQueryTrimsScopedLeaf() {
        let path = [folder("Team"), folder("Mine", scope: scope)]

        #expect(SavedQueryImportPlacement.holdableFolderPath(path, for: nil) == [folder("Team")])
    }

    @Test("The chain is cut where a scoped folder would hold a global one")
    func chainIsCutAtScopeMismatch() {
        let path = [folder("Scoped", scope: scope), folder("Shared"), folder("Below", scope: scope)]

        #expect(SavedQueryImportPlacement.holdableFolderPath(path, for: scope) == [folder("Scoped", scope: scope)])
    }

    @Test("A folder of another connection cuts the chain and the rest of it")
    func otherScopeCutsTheChain() {
        let path = [folder("Mine", scope: scope), folder("Theirs", scope: otherScope)]

        #expect(SavedQueryImportPlacement.holdableFolderPath(path, for: scope) == [folder("Mine", scope: scope)])
        #expect(SavedQueryImportPlacement.holdableFolderPath(path, for: otherScope).isEmpty)
    }

    @Test("A blank folder name ends the path")
    func blankNameEndsThePath() {
        let path = [folder("Team"), folder("  "), folder("After")]

        #expect(SavedQueryImportPlacement.holdableFolderPath(path, for: nil) == [folder("Team")])
    }

    @Test("A blank imported name is taken from the SQL")
    func blankNameIsDerived() {
        #expect(SavedQueryImportPlacement.importedName(planned("  ", sql: "-- Active users\nSELECT * FROM users")) == "Active users")
        #expect(SavedQueryImportPlacement.importedName(planned("", sql: "SELECT 2")) == "SELECT 2")
    }

    @Test("A named import keeps its name as the file spells it")
    func namedImportKeepsItsName() {
        #expect(SavedQueryImportPlacement.importedName(planned(" Daily ")) == " Daily ")
    }
}
