import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Connection list row")
struct ConnectionListRowModelTests {
    private let prod = ConnectionTag(name: "prod", color: .red)
    private let eu = ConnectionTag(name: "eu", color: .blue)
    private let billing = ConnectionTag(name: "billing", color: .green)

    @Test("Two tags are named, the rest are counted, and all of them are spoken")
    func tagsAreCapped() {
        let connection = DatabaseConnection(name: "Prod", type: .postgresql, tagIds: [prod.id, eu.id, billing.id])

        let row = ConnectionListRowModel(connection: connection, section: .connections, tags: [prod, eu, billing], groups: [])

        #expect(row.tags.map(\.name) == ["prod", "eu"])
        #expect(row.hiddenTagCount == 1)
        #expect(row.accessibilityLabel.contains("billing"))
    }

    @Test("Only a Favorites or Recent row names the group, because a tree row already sits under it")
    func groupLabelOnAliasRows() {
        let group = ConnectionGroup(name: "Acme", color: .purple)
        let connection = DatabaseConnection(name: "Prod", type: .mysql, groupId: group.id)

        let treeRow = ConnectionListRowModel(connection: connection, section: .connections, tags: [], groups: [group])
        let favoriteRow = ConnectionListRowModel(connection: connection, section: .favorites, tags: [], groups: [group])
        let recentRow = ConnectionListRowModel(connection: connection, section: .recent, tags: [], groups: [group])

        #expect(treeRow.groupLabel == nil)
        #expect(favoriteRow.groupLabel == ConnectionListLabel(name: "Acme", color: .purple))
        #expect(recentRow.groupLabel?.name == "Acme")
    }

    @Test("An unnamed connection is titled by its host, and nothing is joined with a middle dot")
    func titleAndSeparators() {
        let connection = DatabaseConnection(type: .mysql, host: "db.acme.io", tagIds: [prod.id], isFavorite: true)

        let row = ConnectionListRowModel(connection: connection, section: .connections, tags: [prod], groups: [])

        #expect(row.title == "db.acme.io")
        #expect(!row.accessibilityLabel.contains("·"))
    }
}
