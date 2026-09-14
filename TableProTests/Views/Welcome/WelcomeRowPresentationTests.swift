//
//  WelcomeRowPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@MainActor
@Suite("Welcome row presentation")
struct WelcomeRowPresentationTests {
    private func tag(_ name: String) -> ConnectionTag {
        ConnectionTag(name: name, color: .blue)
    }

    @Test("Two tags are named and the rest are counted")
    func tagsAreCapped() {
        let connection = DatabaseConnection(name: "Prod", host: "db.acme.io", database: "app", type: .postgresql)
        let model = WelcomeRowPresentation.savedConnection(
            connection,
            section: .connections,
            tags: [tag("prod"), tag("eu"), tag("billing")],
            group: nil,
            groupPath: [],
            isDriverRejected: false
        )

        #expect(model.tags.map(\.name) == ["prod", "eu"])
        #expect(model.hiddenTagCount == 1)
    }

    @Test("Only a Favorites or Recent row names the group, because a tree row already sits under it")
    func groupLabelOnlyOnAliasRows() {
        let group = ConnectionGroup(name: "Acme", color: .red)
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.groupId = group.id

        let treeRow = WelcomeRowPresentation.savedConnection(
            connection, section: .connections, tags: [], group: group, groupPath: ["Acme"], isDriverRejected: false
        )
        let favoriteRow = WelcomeRowPresentation.savedConnection(
            connection, section: .favorites, tags: [], group: group, groupPath: ["Acme"], isDriverRejected: false
        )

        #expect(treeRow.groupLabel == nil)
        #expect(favoriteRow.groupLabel == WelcomeTagLabel(name: "Acme", color: .red))
    }

    @Test("The identity color is carried only when one was picked")
    func identityColor() {
        let plain = DatabaseConnection(name: "Plain", type: .mysql)
        var colored = DatabaseConnection(name: "Colored", type: .mysql)
        colored.color = .green

        let plainModel = WelcomeRowPresentation.savedConnection(
            plain, section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )
        let coloredModel = WelcomeRowPresentation.savedConnection(
            colored, section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )

        #expect(plainModel.identityColor == nil)
        #expect(coloredModel.identityColor == .green)
    }

    @Test("A shared endpoint drops the default port and joins the database with a slash")
    func sharedEndpoint() {
        #expect(WelcomeRowPresentation.endpoint(host: "db.acme.io", port: 5_432, defaultPort: 5_432, database: "app")
            == "db.acme.io/app")
        #expect(WelcomeRowPresentation.endpoint(host: "db.acme.io", port: 6_543, defaultPort: 5_432, database: "")
            == "db.acme.io:6543")
        #expect(WelcomeRowPresentation.endpoint(host: "", port: 0, defaultPort: 0, database: "~/data.sqlite")
            == "~/data.sqlite")
    }

    @Test("The tooltip carries the account, the group path and the tags, and no middle dots")
    func tooltip() {
        var connection = DatabaseConnection(
            name: "Prod", host: "db.acme.io", database: "app", username: "admin", type: .postgresql
        )
        connection.localOnly = true
        let text = WelcomeRowPresentation.tooltip(
            for: connection,
            groupPath: ["Clients", "Acme"],
            tags: [tag("prod")]
        )

        #expect(text.contains("admin@db.acme.io"))
        #expect(text.contains("Clients / Acme"))
        #expect(text.contains("prod"))
        #expect(!text.contains("·"))
    }
}
