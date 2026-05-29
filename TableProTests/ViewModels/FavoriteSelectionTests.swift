import Foundation
@testable import TablePro
import Testing

@Suite("FavoriteSelection")
struct FavoriteSelectionTests {
    private func roundTrip(_ selection: FavoriteSelection) -> FavoriteSelection? {
        FavoriteSelection(rawValue: selection.rawValue)
    }

    @Test("Table with database and schema round trips")
    func tableFull() {
        let selection = FavoriteSelection.table(database: "shop", schema: "public", name: "users")
        #expect(roundTrip(selection) == selection)
    }

    @Test("Table without database or schema round trips")
    func tableBare() {
        let selection = FavoriteSelection.table(database: nil, schema: nil, name: "users")
        #expect(roundTrip(selection) == selection)
    }

    @Test("Node round trips")
    func node() {
        let selection = FavoriteSelection.node(id: "fav-\(UUID().uuidString)")
        #expect(roundTrip(selection) == selection)
    }

    @Test("Same table in different databases is distinct")
    func databaseScoped() {
        let db1 = FavoriteSelection.table(database: "db1", schema: "public", name: "users")
        let db2 = FavoriteSelection.table(database: "db2", schema: "public", name: "users")
        #expect(db1 != db2)
        #expect(db1.rawValue != db2.rawValue)
    }

    @Test("Garbage and legacy raw values decode to nil")
    func invalidRawValues() {
        #expect(FavoriteSelection(rawValue: "") == nil)
        #expect(FavoriteSelection(rawValue: "fav-123") == nil)
        #expect(FavoriteSelection(rawValue: "table:public.users") == nil)
        #expect(FavoriteSelection(rawValue: "table\u{1}public\u{1}users") == nil)
    }
}
