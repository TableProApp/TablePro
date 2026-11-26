import Foundation
@testable import TableProMobile
import TableProModels
import Testing

private struct Item: Identifiable, Equatable, Codable {
    let id: Int
    var name: String
    var note: String = ""
}

// A model whose merged copy no longer decodes: a name and a note together are refused.
private struct Fragile: Identifiable, Equatable, Codable {
    let id: Int
    var name: String
    var note: String

    init(id: Int, name: String, note: String) {
        self.id = id
        self.name = name
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decode(String.self, forKey: .note)
        guard name.isEmpty || note.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .note, in: container, debugDescription: "both set")
        }
    }
}

// A write made from a copy a pass has since moved goes on top of what the pass wrote.
struct LibraryRebaseTests {
    private let base = [Item(id: 1, name: "a"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]

    @Test("What the write changed takes its side, and every other record the store's")
    func changesTakeTheWritesSide() {
        let written = [Item(id: 1, name: "a renamed"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let stored = [Item(id: 1, name: "a"), Item(id: 2, name: "b from the Mac"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).items == [
            Item(id: 1, name: "a renamed"), Item(id: 2, name: "b from the Mac"), Item(id: 3, name: "c")
        ])
    }

    @Test("A record both sides changed keeps the pass's fields and takes only the ones the write changed")
    func bothSidesChangedMergesByField() {
        let written = [Item(id: 1, name: "a renamed"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let stored = [Item(id: 1, name: "a", note: "from the Mac"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).items.first == Item(id: 1, name: "a renamed", note: "from the Mac"))
    }

    @Test("A rename made on a stale copy keeps the stricter Safe Mode a pass brought")
    func aStaleRenameKeepsAPulledSafeMode() throws {
        let before = DatabaseConnection(name: "Orders", type: .postgresql, host: "db.example.com")
        var renamed = before
        renamed.name = "Orders (prod)"
        var tightened = before
        tightened.safeModeLevel = .readOnly

        let rebased = try #require(LibraryRebase.rebased([renamed], from: [before], onto: [tightened]).items.first)

        #expect(rebased.name == "Orders (prod)")
        #expect(rebased.safeModeLevel == .readOnly)
        #expect(rebased.host == "db.example.com")
    }

    @Test("A change that cannot be merged keeps the pass's copy and is named, so the person is told")
    func anUnmergedChangeIsNamed() {
        let base = [Fragile(id: 1, name: "", note: "")]
        let written = [Fragile(id: 1, name: "renamed", note: "")]
        let stored = [Fragile(id: 1, name: "", note: "from the Mac")]

        let rebased = LibraryRebase.rebased(written, from: base, onto: stored)

        #expect(rebased.items == stored)
        #expect(rebased.unmerged == [1])
    }

    @Test("A library change that merges over a pass names nothing and keeps the edit")
    func aMergedLibraryChangeNamesNothing() {
        let connection = DatabaseConnection(name: "Orders", type: .postgresql)
        var renamed = connection
        renamed.name = "Orders (prod)"
        let library = CoreLibraryStore.Library(connections: [connection], groups: [], tags: [])

        let merged = LibraryRebase.rebased(
            CoreLibraryStore.Library(connections: [renamed], groups: [], tags: []),
            from: library,
            onto: library
        )

        #expect(merged.unmerged.isEmpty)
        #expect(merged.library.connections.map(\.name) == ["Orders (prod)"])
    }

    @Test("A record the write added joins, one it removed goes, and one the pass added stays")
    func additionsAndRemovals() {
        let written = [Item(id: 1, name: "a"), Item(id: 2, name: "b"), Item(id: 4, name: "new here")]
        let stored = base + [Item(id: 5, name: "new there")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).items.map(\.id) == [1, 2, 5, 4])
    }

    @Test("A record the write changed and the pass removed comes back")
    func anEditRevivesARemovedRecord() {
        let written = [Item(id: 1, name: "a renamed"), Item(id: 2, name: "b"), Item(id: 3, name: "c")]
        let stored = [Item(id: 2, name: "b"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(written, from: base, onto: stored).items.map(\.id) == [2, 3, 1])
    }

    @Test("A record the pass removed and the write left alone stays removed")
    func aRemovalElsewhereStands() {
        let stored = [Item(id: 2, name: "b"), Item(id: 3, name: "c")]

        #expect(LibraryRebase.rebased(base, from: base, onto: stored).items.map(\.id) == [2, 3])
    }
}
