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

    @Test("A team row's tooltip names who last changed it and when, as the core reports, and no middle dots")
    func teamRowNamesItsLastChange() {
        let connection = DatabaseConnection(name: "Prod", host: "db.acme.io", database: "app", type: .postgresql)
        let date = Date(timeIntervalSince1970: 1_795_800_000)

        let named = WelcomeRowPresentation.teamConnection(
            connection, section: .teamLibrary, lastWriter: "Grace Hopper", lastChangedAt: date
        )
        let undated = WelcomeRowPresentation.teamConnection(
            connection, section: .teamLibrary, lastWriter: "Grace Hopper", lastChangedAt: nil
        )
        let unnamed = WelcomeRowPresentation.teamConnection(
            connection, section: .teamLibrary, lastWriter: nil, lastChangedAt: date
        )
        let plain = WelcomeRowPresentation.savedConnection(
            connection, section: .teamLibrary, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )

        #expect(named.tooltip.hasSuffix(
            "Last changed by Grace Hopper on " + date.formatted(date: .abbreviated, time: .shortened)
        ))
        #expect(undated.tooltip.hasSuffix("Last changed by Grace Hopper"))
        #expect(named.detail == plain.detail)
        #expect(unnamed == plain)
        #expect(!named.tooltip.contains("·"))
    }

    // MARK: - Icons

    private static let customIcon = "server.rack"
    private static let undrawableIcon = "made.up.symbol"

    private func makeConnection(iconName: String?) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.iconName = iconName
        return connection
    }

    private func shared(iconName: String?, additionalFields: [String: String]? = nil) -> LinkedConnection {
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
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: additionalFields,
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

    // The tile takes the engine's glyph whenever this is nil, so a name from a newer release never draws an empty tile.
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

    // A custom icon replaces the engine logo, so the tooltip is where the engine stays visible.
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

    // CockroachDB's logo is a 2500pt artboard, which the width-only rename image view would take as its height.
    @Test("An engine logo in the rename field fits the glyph's 16pt box")
    func renameGlyphFitsTheField() throws {
        let side = WelcomeRowPresentation.renameGlyphSide
        for type in [DatabaseType.cockroachdb, .postgresql, .mysql] {
            let glyph = try #require(WelcomeRowPresentation.renameGlyph(for: DatabaseConnection(name: "Prod", type: type)))
            #expect(glyph.size.width <= side && glyph.size.height <= side, "\(type.rawValue): \(glyph.size)")
            #expect(glyph.size.width > 0 && glyph.size.height > 0, "\(type.rawValue)")
        }
    }

    // MARK: - Environment

    private func withEnvironment(_ environment: ConnectionEnvironment) -> DatabaseConnection {
        var connection = makeConnection(iconName: nil)
        connection.additionalFields[ConnectionEnvironment.fieldKey] = environment.rawValue
        return connection
    }

    private func savedRow(_ connection: DatabaseConnection) -> WelcomeConnectionRowModel {
        WelcomeRowPresentation.savedConnection(
            connection, section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )
    }

    private func row(status: ConnectionDisplayStatus) -> WelcomeConnectionRowModel {
        WelcomeConnectionRowModel(
            id: UUID(),
            name: "Prod",
            detail: "db.acme.io/app",
            type: .postgresql,
            iconName: nil,
            identityColor: nil,
            environment: .production,
            tags: [],
            hiddenTagCount: 0,
            groupLabel: nil,
            isLocalOnly: false,
            isDriverRejected: false,
            tooltip: "",
            status: status
        )
    }

    @Test("A saved row carries its environment, and a connection without one shows none")
    func savedRowCarriesEnvironment() {
        #expect(savedRow(withEnvironment(.production)).environment == .production)
        #expect(savedRow(withEnvironment(.local)).environment == .local)
        #expect(savedRow(makeConnection(iconName: nil)).environment == .none)
    }

    @Test("A linked row reads the environment from its file")
    func sharedRowCarriesEnvironment() {
        let staging = shared(iconName: nil, additionalFields: [ConnectionEnvironment.fieldKey: "staging"])
        let plain = shared(iconName: nil)

        #expect(WelcomeRowPresentation.sharedConnection(staging, section: .linkedFolders).environment == .staging)
        #expect(WelcomeRowPresentation.sharedConnection(plain, section: .linkedFolders).environment == .none)
    }

    @Test("VoiceOver reads the environment with the name and the engine, and nothing for none")
    func accessibilityLabelNamesEnvironment() {
        #expect(savedRow(withEnvironment(.production)).accessibilityLabel == "Prod, PostgreSQL, Production environment")
        #expect(savedRow(withEnvironment(.development)).accessibilityLabel == "Prod, PostgreSQL, Development environment")
        #expect(savedRow(makeConnection(iconName: nil)).accessibilityLabel == "Prod, PostgreSQL")
    }

    @Test("The accessibility value keeps what the row shows: flags, endpoint, group and tags")
    func accessibilityValueKeepsRowContent() {
        let group = ConnectionGroup(name: "Acme")
        var connection = DatabaseConnection(name: "Prod", host: "db.acme.io", database: "app", type: .postgresql)
        connection.localOnly = true
        connection.groupId = group.id
        let model = WelcomeRowPresentation.savedConnection(
            connection,
            section: .favorites,
            tags: [tag("api"), tag("eu"), tag("billing")],
            group: group,
            groupPath: ["Acme"],
            isDriverRejected: true
        )

        #expect(model.accessibilityValue.components(separatedBy: ", ")
            == ["Plugin not loaded", "Local only", model.detail, "Acme", "api", "eu", "+1"])
    }

    @Test("A row reads its status only while it shows a mark")
    func accessibilityValueReadsVisibleStatus() {
        #expect(row(status: .connecting).accessibilityValue == "Connecting, db.acme.io/app")
        #expect(row(status: .failed(cause: nil)).accessibilityValue == "Couldn't connect, db.acme.io/app")
        #expect(row(status: .connected).accessibilityValue == "db.acme.io/app")
        #expect(row(status: .notConnected).accessibilityValue == "db.acme.io/app")
    }

    @Test("A connection named after its address shows the address once")
    func addressNamedRowShowsItOnce() {
        var unnamed = DatabaseConnection(name: "", host: "db.example.com", database: "app", type: .postgresql)
        unnamed.name = unnamed.connectionSubtitle
        let named = DatabaseConnection(name: "Prod", host: "db.example.com", database: "app", type: .postgresql)

        let unnamedModel = WelcomeRowPresentation.savedConnection(
            unnamed, section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )
        let namedModel = WelcomeRowPresentation.savedConnection(
            named, section: .connections, tags: [], group: nil, groupPath: [], isDriverRejected: false
        )

        #expect(unnamedModel.detail.isEmpty)
        #expect(!unnamedModel.hasSecondLine)
        #expect(namedModel.detail == named.connectionSubtitle)
        #expect(namedModel.hasSecondLine)
    }
}
