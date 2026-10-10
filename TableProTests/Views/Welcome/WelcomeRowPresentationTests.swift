//
//  WelcomeRowPresentationTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProConnectionLibrary
import TableProImport
import Testing

@MainActor
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
        #expect(favoriteRow.groupLabel == WelcomeTagLabel(name: "Acme", color: .red, symbolName: "folder.fill"))
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

    // MARK: - Icons

    private static let customIcon = "server.rack"
    private static let undrawableIcon = "made.up.symbol"

    private func makeConnection(iconName: String?) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.iconName = iconName
        return connection
    }

    private func shared(iconName: String?) -> LinkedConnection {
        let exportable = ExportableConnection(
            name: "Shared",
            host: "db.acme.io",
            port: 5_432,
            database: "app",
            username: "admin",
            type: DatabaseType.postgresql.rawValue,
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            iconName: iconName,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
        return LinkedConnection(
            id: UUID(),
            connection: exportable,
            folderId: UUID(),
            sourceFileURL: URL(fileURLWithPath: "/tmp/shared.tablepro")
        )
    }

    @Test("A saved row carries the connection's icon, and none when it has none")
    func savedRowCarriesIcon() {
        let custom = WelcomeRowPresentation.savedConnection(
            makeConnection(iconName: Self.customIcon),
            section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )
        let plain = WelcomeRowPresentation.savedConnection(
            makeConnection(iconName: nil),
            section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )

        #expect(custom.iconName == Self.customIcon)
        #expect(plain.iconName == nil)
    }

    @Test("A shared row keeps a well-formed icon from the file and drops a malformed one")
    func sharedRowNormalizesIcon() {
        let padded = WelcomeRowPresentation.sharedConnection(shared(iconName: " server.rack "), section: .linkedFolders)
        let junk = WelcomeRowPresentation.sharedConnection(shared(iconName: "../server rack"), section: .linkedFolders)
        let unknown = WelcomeRowPresentation.sharedConnection(shared(iconName: Self.undrawableIcon), section: .linkedFolders)

        #expect(padded.iconName == Self.customIcon)
        #expect(junk.iconName == nil)
        #expect(unknown.iconName == Self.undrawableIcon)
    }

    /// The tile draws `LibraryGlyph.connectionImage`, which takes the engine's glyph whenever this
    /// resolves to nil. A name kept from a newer release must not draw an empty tile.
    @Test("A tile falls back to the engine for no icon or one this Mac cannot draw")
    func tileFallsBackToEngine() {
        #expect(LibraryGlyph.customSymbol(nil) == nil)
        #expect(LibraryGlyph.customSymbol(Self.undrawableIcon) == nil)
        #expect(LibraryGlyph.customSymbol(Self.customIcon) == Self.customIcon)
    }

    @Test("A group row and a group label draw the group's own symbol, and the folder by default")
    func groupDrawsItsOwnSymbol() {
        let custom = ConnectionGroup(name: "Servers", color: .blue, iconName: Self.customIcon)
        let plain = ConnectionGroup(name: "Acme", color: .red)
        let undrawable = ConnectionGroup(name: "Newer", iconName: Self.undrawableIcon)
        let expected = LibraryGlyph.groupSymbol(Self.customIcon)

        #expect(expected != "folder.fill")
        #expect(WelcomeRowPresentation.group(custom, connectionCount: 2).symbolName == expected)
        #expect(WelcomeRowPresentation.groupLabel(custom).symbolName == expected)
        #expect(WelcomeRowPresentation.group(plain, connectionCount: 0).symbolName == "folder.fill")
        #expect(WelcomeRowPresentation.group(undrawable, connectionCount: 0).symbolName == "folder.fill")
        #expect(WelcomeRowPresentation.group(custom, connectionCount: 2).connectionCount == 2)
    }

    @Test("A tag label draws the tag whatever its group draws")
    func tagLabelDrawsTag() {
        var connection = makeConnection(iconName: nil)
        let group = ConnectionGroup(name: "Servers", iconName: Self.customIcon)
        connection.groupId = group.id
        let row = WelcomeRowPresentation.savedConnection(
            connection, section: .favorites, tags: [tag("prod")], group: group, groupPath: ["Servers"],
            isDriverRejected: false
        )

        #expect(row.tags.map(\.symbolName) == ["tag.fill"])
        #expect(row.groupLabel?.symbolName == LibraryGlyph.groupSymbol(Self.customIcon))
    }

    /// A custom icon replaces the engine logo, so the tooltip is where the engine stays visible.
    @Test("The tooltip names the engine, for a saved and for a shared connection")
    func tooltipNamesEngine() {
        let saved = WelcomeRowPresentation.tooltip(
            for: makeConnection(iconName: Self.customIcon), groupPath: [], tags: []
        )
        let linked = WelcomeRowPresentation.sharedConnection(shared(iconName: Self.customIcon), section: .linkedFolders)

        #expect(saved.components(separatedBy: "\n").contains("PostgreSQL"))
        #expect(linked.tooltip.components(separatedBy: "\n").contains("PostgreSQL"))
    }

    @Test("The rename field shows the row's own glyph")
    func renameGlyphIsTheRowGlyph() throws {
        let customGroup = ConnectionGroup(name: "Servers", iconName: Self.customIcon)
        let groupGlyph = try #require(WelcomeRowPresentation.renameGlyph(for: customGroup))
        let groupSymbol = try #require(NSImage(
            systemSymbolName: LibraryGlyph.groupSymbol(Self.customIcon), accessibilityDescription: nil
        ))
        let folder = try #require(WelcomeRowPresentation.renameGlyph(for: ConnectionGroup(name: "Acme")))
        #expect(groupGlyph.tiffRepresentation == groupSymbol.tiffRepresentation)
        #expect(groupGlyph.tiffRepresentation != folder.tiffRepresentation)

        let custom = try #require(WelcomeRowPresentation.renameGlyph(for: makeConnection(iconName: Self.customIcon)))
        let engine = try #require(WelcomeRowPresentation.renameGlyph(for: makeConnection(iconName: nil)))
        let undrawable = try #require(WelcomeRowPresentation.renameGlyph(for: makeConnection(iconName: Self.undrawableIcon)))
        #expect(custom.tiffRepresentation != engine.tiffRepresentation)
        #expect(undrawable.tiffRepresentation == engine.tiffRepresentation)
        #expect(custom.isTemplate)
        #expect(engine.isTemplate)
    }

    /// CockroachDB's logo is a 2500pt artboard. The rename field's image view is constrained in width
    /// only, so an unfitted logo would take that as its height and spill over the rows around it.
    @Test("An engine logo in the rename field fits the glyph's 16pt box")
    func renameGlyphFitsTheField() throws {
        let side = WelcomeRowPresentation.renameGlyphSide
        for type in [DatabaseType.cockroachdb, .postgresql, .mysql] {
            let glyph = try #require(WelcomeRowPresentation.renameGlyph(for: DatabaseConnection(name: "Prod", type: type)))
            #expect(glyph.size.width <= side && glyph.size.height <= side, "\(type.rawValue): \(glyph.size)")
            #expect(glyph.size.width > 0 && glyph.size.height > 0, "\(type.rawValue)")
        }
    }
}
