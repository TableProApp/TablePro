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
    private func parsed(_ link: String?) throws -> ConnectionBundle {
        let url = try #require(link.flatMap(URL.init(string:)))
        guard case .success(.importConnection(let bundle)) = DeeplinkParser.parse(url) else {
            Issue.record("The link did not parse as a connection import")
            throw CocoaError(.coderReadCorrupt)
        }
        return bundle
    }

    private func parsedSettings(_ items: [URLQueryItem]) throws -> ExportableConnection {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "name", value: "Staging"),
            URLQueryItem(name: "host", value: "db.example.com"),
            URLQueryItem(name: "type", value: "PostgreSQL")
        ] + items
        let bundle = try parsed(components.url?.absoluteString)
        return try #require(bundle.connections.first).settings
    }

    private func imported(_ settings: ExportableConnection) -> DatabaseConnection {
        DatabaseConnection(
            importing: settings,
            id: UUID(),
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { _ in false }
        )
    }

    private func queryValue(_ name: String, in link: String) -> String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == name }?.value
    }

    // MARK: - Connection icon

    @Test("A file export and Copy as JSON carry the connection's icon")
    func exportCarriesIcon() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.iconName = "server.rack"

        let bundle = try library.exporter.connectionsOnlyBundle(for: [connection])
        let json = ConnectionShareLink.compactJSON(for: connection, exporter: library.exporter)
        let fromJSON = try JSONDecoder().decode(ExportableConnection.self, from: Data(json.utf8))

        #expect(bundle.connections.first?.settings.iconName == "server.rack")
        #expect(fromJSON.iconName == "server.rack")
    }

    @Test("Copy TablePro Link carries the icon and the import keeps it")
    func linkCarriesIcon() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.iconName = "lock.shield"

        let link = try #require(ConnectionShareLink.deeplink(for: connection, exporter: library.exporter))
        let settings = try #require(try parsed(link).connections.first).settings

        #expect(queryValue("icon", in: link) == "lock.shield")
        #expect(settings.iconName == "lock.shield")
        #expect(imported(settings).iconName == "lock.shield")
    }

    @Test("A connection with the engine icon puts no icon in the link")
    func linkOmitsDefaultIcon() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }

        let link = try #require(ConnectionShareLink.deeplink(for: DatabaseConnection(name: "Plain"), exporter: library.exporter))

        #expect(URLComponents(string: link)?.queryItems?.contains { $0.name == "icon" } == false)
    }

    @Test("A malformed icon in a link or a file is dropped, and one this Mac cannot draw is kept")
    func importNormalizesIcon() throws {
        #expect(try parsedSettings([URLQueryItem(name: "icon", value: "../../secret")]).iconName == nil)
        #expect(try parsedSettings([URLQueryItem(name: "icon", value: "made.up.symbol")]).iconName == "made.up.symbol")

        var file = ExportableConnection(
            name: "Prod", host: "db.example.com", port: 5_432, database: "", username: "", type: "PostgreSQL"
        )
        file.iconName = "Not A Symbol"
        #expect(imported(file).iconName == nil)
    }

    // MARK: - Link timeouts

    @Test("Copy TablePro Link carries the connect and query timeouts")
    func linkCarriesTimeouts() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.connectTimeoutSeconds = 12
        connection.queryTimeoutSeconds = 30

        let link = try #require(ConnectionShareLink.deeplink(for: connection, exporter: library.exporter))
        let settings = try #require(try parsed(link).connections.first).settings
        let connected = imported(settings)

        #expect(settings.connectTimeoutSeconds == 12)
        #expect(settings.queryTimeoutSeconds == 30)
        #expect(connected.connectTimeoutSeconds == 12)
        #expect(connected.queryTimeoutSeconds == 30)
    }

    @Test("A link keeps a disabled query timeout")
    func linkKeepsDisabledQueryTimeout() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.queryTimeoutSeconds = 0

        let link = ConnectionShareLink.deeplink(for: connection, exporter: library.exporter)

        #expect(try parsed(link).connections.first?.settings.queryTimeoutSeconds == 0)
    }

    @Test("A link with an out-of-range timeout imports the default, as a file does")
    func linkRejectsOutOfRangeTimeouts() throws {
        let settings = try parsedSettings([
            URLQueryItem(name: "connectTimeoutSeconds", value: "601"),
            URLQueryItem(name: "queryTimeoutSeconds", value: "-1")
        ])

        #expect(settings.connectTimeoutSeconds == nil)
        #expect(settings.queryTimeoutSeconds == nil)
        #expect(imported(settings).connectTimeoutSeconds == nil)
        #expect(imported(settings).queryTimeoutSeconds == nil)
    }

    @Test("A link with an unreadable timeout imports the default")
    func linkIgnoresUnreadableTimeouts() throws {
        let settings = try parsedSettings([
            URLQueryItem(name: "connectTimeoutSeconds", value: "soon"),
            URLQueryItem(name: "queryTimeoutSeconds", value: "")
        ])

        #expect(settings.connectTimeoutSeconds == nil)
        #expect(settings.queryTimeoutSeconds == nil)
    }

    // MARK: - Exported groups

    @Test("Two groups that share a name export as two groups, each with its own color and icon")
    func sameNamedGroupsStayDistinct() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let clientA = ConnectionGroup(name: "Client A")
        let clientB = ConnectionGroup(name: "Client B")
        let prodA = ConnectionGroup(name: "Prod", color: .red, iconName: "flame", parentId: clientA.id)
        let prodB = ConnectionGroup(name: "Prod", color: .green, iconName: "leaf", parentId: clientB.id)
        for group in [clientA, clientB, prodA, prodB] {
            try library.groups.addGroup(group)
        }
        var inB = DatabaseConnection(name: "Billing", type: .postgresql)
        inB.groupId = prodB.id
        var inA = DatabaseConnection(name: "Orders", host: "orders.example.com", type: .postgresql)
        inA.groupId = prodA.id

        let bundle = try library.exporter.connectionsOnlyBundle(for: [inB, inA])
        let leafB = bundle.groupChain(bundle.connection("c1")?.groupRef).last
        let leafA = bundle.groupChain(bundle.connection("c2")?.groupRef).last

        #expect(bundle.groups.count == 4)
        #expect(leafB?.color == ConnectionColor.green.rawValue)
        #expect(leafB?.iconName == "leaf")
        #expect(leafA?.color == ConnectionColor.red.rawValue)
        #expect(leafA?.iconName == "flame")
    }

    @Test("No group entry is written when no exported connection is in a group")
    func ungroupedExportHasNoGroups() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        try library.groups.addGroup(ConnectionGroup(name: "Unused", iconName: "star"))

        let bundle = try library.exporter.connectionsOnlyBundle(for: [DatabaseConnection(name: "Loose")])

        #expect(bundle.groups.isEmpty)
    }

    @Test("An imported group takes the file's color and icon, and drops a malformed icon")
    func importedGroupTakesColorAndIcon() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let settings = { (name: String, host: String) in
            ExportableConnection(name: name, host: host, port: 5_432, database: "", username: "", type: "PostgreSQL")
        }
        let bundle = try ConnectionBundle(
            appVersion: "Tests",
            connections: [
                BundleConnection(ref: "c1", settings: settings("Orders", "orders.example.com"), groupRef: "g1"),
                BundleConnection(ref: "c2", settings: settings("Billing", "billing.example.com"), groupRef: "g2")
            ],
            groups: [
                BundleGroup(ref: "g1", name: "Prod", color: ConnectionColor.red.rawValue, iconName: "flame"),
                BundleGroup(ref: "g2", name: "Junk", iconName: "Flame Icon")
            ]
        )

        let outcome = try await library.importDefaults(of: bundle)

        #expect(outcome.connectionsAdded == 2)
        let groups = library.groups.loadGroups()
        let prod = try #require(groups.first { $0.name == "Prod" })
        let junk = try #require(groups.first { $0.name == "Junk" })
        #expect(prod.color == .red)
        #expect(prod.iconName == "flame")
        #expect(junk.color == ConnectionColor.none)
        #expect(junk.iconName == nil)
    }

    // MARK: - Link tags

    @Test("A link with several tags imports every one of them, renamed or not")
    func linkImportsEveryTag() throws {
        let bundle = try parsed(
            "tablepro://import?name=Staging&host=db.example.com&type=PostgreSQL&tagName=prod&tagName=billing"
        )
        let entry = try #require(bundle.connections.first)
        var renamed = entry.settings
        renamed.name = "Staging Copy"

        let edited = bundle.replacingSettings(renamed, of: entry.ref)

        #expect(edited.tags.map(\.name) == ["prod", "billing"])
        #expect(edited.connections.first?.settings.name == "Staging Copy")
        #expect(edited.connections.first?.tagNames == ["prod", "billing"])
    }
}
