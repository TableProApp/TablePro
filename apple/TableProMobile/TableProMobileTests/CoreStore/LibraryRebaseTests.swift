import Foundation
@testable import TableProMobile
import TableProModels
import Testing

private struct Item: Identifiable, Equatable, Codable {
    let id: Int
    var name: String
    var note: String = ""
}

// A write made from a copy a pass has since moved goes on top of what the pass wrote.
struct LibraryRebaseTests {
    private let base = [Item(id: 1, name: "a"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]

    @Test("What the write changed takes its side, and every other record the store's")
    func changesTakeTheWritesSide() {
        let written = [Item(id: 1, name: "a renamed"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let stored = [Item(id: 1, name: "a"), Item(id: 2, name: "b from the Mac"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored) == [
            Item(id: 1, name: "a renamed"), Item(id: 2, name: "b from the Mac"), Item(id: 3, name: "c")
        ])
    }

    @Test("A record both sides changed keeps the pass's fields and takes only the ones the write changed")
    func bothSidesChangedMergesByField() {
        let written = [Item(id: 1, name: "a renamed"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let stored = [Item(id: 1, name: "a", note: "from the Mac"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).first == Item(id: 1, name: "a renamed", note: "from the Mac"))
    }

    @Test("A rename made on a stale copy keeps the stricter Safe Mode a pass brought")
    func aStaleRenameKeepsAPulledSafeMode() throws {
        let before = DatabaseConnection(name: "Orders", type: .postgresql, host: "db.example.com")
        var renamed = before
        renamed.name = "Orders (prod)"
        var tightened = before
        tightened.safeModeLevel = .readOnly

        let rebased = try #require(LibraryRebase.rebased([renamed], from: [before], onto: [tightened]).first)

        #expect(rebased.name == "Orders (prod)")
        #expect(rebased.safeModeLevel == .readOnly)
        #expect(rebased.host == "db.example.com")
    }

    @Test("A record the write added joins, one it removed goes, and one the pass added stays")
    func additionsAndRemovals() {
        let written = [Item(id: 1, name: "a"), Item(id: 2, name: "b"), Item(id: 4, name: "new here")]
        let stored = base + [Item(id: 5, name: "new there")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).map(\.id) == [1, 2, 5, 4])
    }

    @Test("A record the write changed and the pass removed comes back")
    func anEditRevivesARemovedRecord() {
        let written = [Item(id: 1, name: "a renamed"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let stored = [Item(id: 2, name: "b"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).map(\.id) == [2, 3, 1])
    }

    @Test("A record the pass removed and the write left alone stays removed")
    func aRemovalElsewhereStands() {
        let stored = [Item(id: 2, name: "b"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(base, from: base, onto: stored).map(\.id) == [2, 3])
    }
}
