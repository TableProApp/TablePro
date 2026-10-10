//
//  ConnectionSharingIconTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct ConnectionSharingIconTests {
    private func parsedLink(for connection: DatabaseConnection) throws -> ExportableConnection {
        let link = try #require(ConnectionExportService.buildImportDeeplink(for: connection))
        return try #require(importedConnection(from: URL(string: link)))
    }

    private func parsedLink(_ items: [URLQueryItem]) throws -> ExportableConnection {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "name", value: "Staging"),
            URLQueryItem(name: "host", value: "db.example.com"),
            URLQueryItem(name: "type", value: "PostgreSQL")
        ] + items
        return try #require(importedConnection(from: components.url))
    }

    private func importedConnection(from url: URL?) -> ExportableConnection? {
        guard let url, case .success(.importConnection(let parsed)) = DeeplinkParser.parse(url) else { return nil }
        return parsed
    }

    private func imported(_ exportable: ExportableConnection) -> DatabaseConnection {
        ConnectionExportService.buildDatabaseConnection(
            id: UUID(), from: exportable, name: exportable.name,
            tagIdsByName: [:], groupIdsByName: [:]
        )
    }

    // MARK: - Connection icon

    @Test("A file export and Copy as JSON carry the connection's icon")
    func exportCarriesIcon() throws {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.iconName = "server.rack"

        let exported = try #require(ConnectionExportService.buildEnvelope(for: [connection]).connections.first)
        let json = ConnectionExportService.buildCompactJSON(for: connection)
        let fromJSON = try JSONDecoder().decode(ExportableConnection.self, from: Data(json.utf8))

        #expect(exported.iconName == "server.rack")
        #expect(fromJSON.iconName == "server.rack")
    }

    @Test("Copy TablePro Link carries the icon and the import keeps it")
    func linkCarriesIcon() throws {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.iconName = "lock.shield"

        let link = try #require(ConnectionExportService.buildImportDeeplink(for: connection))
        let parsed = try parsedLink(for: connection)

        #expect(URLComponents(string: link)?.queryItems?.first { $0.name == "icon" }?.value == "lock.shield")
        #expect(parsed.iconName == "lock.shield")
        #expect(imported(parsed).iconName == "lock.shield")
    }

    @Test("A connection with the engine icon puts no icon in the link")
    func linkOmitsDefaultIcon() throws {
        let link = try #require(ConnectionExportService.buildImportDeeplink(for: DatabaseConnection(name: "Plain")))

        #expect(URLComponents(string: link)?.queryItems?.contains { $0.name == "icon" } == false)
    }

    @Test("A malformed icon in a link or a file is dropped, and one this Mac cannot draw is kept")
    func importNormalizesIcon() throws {
        #expect(try parsedLink([URLQueryItem(name: "icon", value: "../../secret")]).iconName == nil)
        #expect(try parsedLink([URLQueryItem(name: "icon", value: "made.up.symbol")]).iconName == "made.up.symbol")

        let file = ExportableConnection(
            name: "Prod", host: "db.example.com", port: 5_432, database: "", username: "",
            type: "PostgreSQL", sshConfig: nil, sslConfig: nil, color: nil, iconName: "Not A Symbol",
            tagName: nil, groupName: nil, sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil,
            additionalFields: nil, redisDatabase: nil, startupCommands: nil, localOnly: nil
        )
        #expect(imported(file).iconName == nil)
    }

    // MARK: - Link timeouts

    @Test("Copy TablePro Link carries the connect and query timeouts")
    func linkCarriesTimeouts() throws {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.connectTimeoutSeconds = 12
        connection.queryTimeoutSeconds = 30

        let parsed = try parsedLink(for: connection)
        let connected = imported(parsed)

        #expect(parsed.connectTimeoutSeconds == 12)
        #expect(parsed.queryTimeoutSeconds == 30)
        #expect(connected.connectTimeoutSeconds == 12)
        #expect(connected.queryTimeoutSeconds == 30)
    }

    @Test("A link keeps a disabled query timeout")
    func linkKeepsDisabledQueryTimeout() throws {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.queryTimeoutSeconds = 0

        #expect(try parsedLink(for: connection).queryTimeoutSeconds == 0)
    }

    @Test("A link with an out-of-range timeout imports the default, as a file does")
    func linkRejectsOutOfRangeTimeouts() throws {
        let parsed = try parsedLink([
            URLQueryItem(name: "connectTimeoutSeconds", value: "601"),
            URLQueryItem(name: "queryTimeoutSeconds", value: "-1")
        ])

        #expect(parsed.connectTimeoutSeconds == nil)
        #expect(parsed.queryTimeoutSeconds == nil)
        #expect(imported(parsed).connectTimeoutSeconds == nil)
        #expect(imported(parsed).queryTimeoutSeconds == nil)
    }

    @Test("A link with an unreadable timeout imports the default")
    func linkIgnoresUnreadableTimeouts() throws {
        let parsed = try parsedLink([
            URLQueryItem(name: "connectTimeoutSeconds", value: "soon"),
            URLQueryItem(name: "queryTimeoutSeconds", value: "")
        ])

        #expect(parsed.connectTimeoutSeconds == nil)
        #expect(parsed.queryTimeoutSeconds == nil)
    }

    // MARK: - Exported groups

    @Test("Exported groups come from the groups the connections are in, not from a lookup by name")
    func exportedGroupsResolveById() throws {
        let unrelated = ConnectionGroup(name: "Prod", color: .blue, iconName: "star")
        let clientA = ConnectionGroup(name: "Prod", color: .red, iconName: "flame", parentId: UUID())
        var connection = DatabaseConnection(name: "Orders", type: .postgresql)
        connection.groupId = clientA.id

        let groups = try #require(ConnectionExportService.exportableGroups(for: [connection], in: [unrelated, clientA]))

        #expect(groups.count == 1)
        #expect(groups.first?.name == "Prod")
        #expect(groups.first?.color == ConnectionColor.red.rawValue)
        #expect(groups.first?.iconName == "flame")
    }

    /// The file keys a group by name and the import resolves a connection's group by name, so two
    /// exported groups that share a name become one, and the first connection's group wins.
    @Test("Two exported groups with one name become one entry taken from the first connection's group")
    func sameNamedGroupsKeepTheFirstInExportOrder() throws {
        let clientA = ConnectionGroup(name: "Prod", color: .red, iconName: "flame", parentId: UUID())
        let clientB = ConnectionGroup(name: "Prod", color: .green, iconName: "leaf", parentId: UUID())
        let staging = ConnectionGroup(name: "Staging")
        var inB = DatabaseConnection(name: "Billing", type: .postgresql)
        inB.groupId = clientB.id
        var inA = DatabaseConnection(name: "Orders", type: .postgresql)
        inA.groupId = clientA.id
        var inStaging = DatabaseConnection(name: "Scratch", type: .postgresql)
        inStaging.groupId = staging.id

        let groups = try #require(
            ConnectionExportService.exportableGroups(for: [inB, inA, inStaging], in: [clientA, clientB, staging])
        )
        let names = groups.map(\.name)

        #expect(names == ["Prod", "Staging"])
        #expect(groups[0].color == ConnectionColor.green.rawValue)
        #expect(groups[0].iconName == "leaf")
        #expect(groups[1].color == nil)
        #expect(groups[1].iconName == nil)
    }

    @Test("No group entry is written when no exported connection is in a group")
    func ungroupedExportHasNoGroups() {
        let groups = ConnectionExportService.exportableGroups(
            for: [DatabaseConnection(name: "Loose")],
            in: [ConnectionGroup(name: "Unused")]
        )

        #expect(groups == nil)
    }

    @Test("An imported group takes the file's color and icon, and drops a malformed icon")
    func importedGroupTakesColorAndIcon() {
        let group = ConnectionExportService.importedGroup(
            from: ExportableGroup(name: "Prod", color: ConnectionColor.red.rawValue, iconName: "flame")
        )
        let junk = ConnectionExportService.importedGroup(
            from: ExportableGroup(name: "Prod", color: nil, iconName: "Flame Icon")
        )

        #expect(group.name == "Prod")
        #expect(group.color == .red)
        #expect(group.iconName == "flame")
        #expect(junk.color == ConnectionColor.none)
        #expect(junk.iconName == nil)
    }

    // MARK: - Link tags

    @Test("A link with several tags imports every one of them")
    func linkImportsEveryTag() throws {
        let parsed = try parsedLink([
            URLQueryItem(name: "tagName", value: "prod"),
            URLQueryItem(name: "tagName", value: "billing")
        ])

        let envelope = DeeplinkImportSheet.importEnvelope(for: parsed, named: "Staging Copy")

        #expect(envelope.tags?.map(\.name) == ["prod", "billing"])
        #expect(envelope.connections.first?.name == "Staging Copy")
        #expect(envelope.connections.first?.tagNames == ["prod", "billing"])
    }
}
