//
//  ConnectionShareLinkTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import Testing

@MainActor
struct ConnectionShareLinkTests {
    private func parse(_ link: String) throws -> ConnectionBundle {
        let url = try #require(URL(string: link))
        guard case .success(.importConnection(let bundle)) = DeeplinkParser.parse(url) else {
            Issue.record("The link did not parse as a connection import")
            throw CocoaError(.coderReadCorrupt)
        }
        return bundle
    }

    @Test("A nested group travels as repeated groupName items, root first, and comes back as a path")
    func groupPathRoundTrips() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let client = ConnectionGroup(name: "Client A")
        let production = ConnectionGroup(name: "Production", parentId: client.id)
        try library.groups.addGroup(client)
        try library.groups.addGroup(production)
        var connection = DatabaseConnection(name: "Orders", host: "db.example.com", port: 5_432, type: .postgresql)
        connection.groupId = production.id

        let link = try #require(ConnectionShareLink.deeplink(for: connection, exporter: library.exporter))

        let groupNames = (URLComponents(string: link)?.queryItems ?? [])
            .filter { $0.name == "groupName" }
            .compactMap { $0.value }
        #expect(groupNames == ["Client A", "Production"])
        let bundle = try parse(link)
        #expect(bundle.groupChain(bundle.connections.first?.groupRef).map(\.name) == ["Client A", "Production"])
    }

    @Test("Every tag travels as its own tagName item and comes back")
    func tagsRoundTrip() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let staging = ConnectionTag(name: "staging")
        let reporting = ConnectionTag(name: "reporting")
        try library.tags.addTag(staging)
        try library.tags.addTag(reporting)
        let connection = DatabaseConnection(
            name: "Orders", host: "db.example.com", port: 5_432, type: .postgresql,
            tagIds: [staging.id, reporting.id]
        )

        let link = try #require(ConnectionShareLink.deeplink(for: connection, exporter: library.exporter))

        #expect(try parse(link).connections.first?.tagNames == ["staging", "reporting"])
    }

    @Test("A link with one groupName names a root group")
    func singleGroupNameIsARootGroup() throws {
        let bundle = try parse("tablepro://import?name=Orders&host=db.example.com&type=PostgreSQL&groupName=Production")

        let chain = bundle.groupChain(bundle.connections.first?.groupRef)
        #expect(chain.map(\.name) == ["Production"])
        #expect(chain.first?.parentRef == nil)
    }

    @Test("A link keeps an SSL mode it does not know so the review can warn about it")
    func unknownSSLModeIsKept() throws {
        let bundle = try parse("tablepro://import?name=Orders&host=db.example.com&type=PostgreSQL&sslMode=someFutureMode")

        #expect(bundle.connections.first?.settings.sslConfig?.mode == "someFutureMode")
    }

    @Test("A link writes the canonical SSL spelling")
    func linkWritesCanonicalSSL() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let connection = DatabaseConnection(
            name: "Orders", host: "db.example.com", port: 5_432, type: .postgresql,
            sslConfig: SSLConfiguration(mode: .verifyIdentity)
        )

        let link = try #require(ConnectionShareLink.deeplink(for: connection, exporter: library.exporter))

        #expect(URLComponents(string: link)?.queryItems?.first { $0.name == "sslMode" }?.value == "Verify Identity")
    }

    @Test("Copy as JSON is the settings object alone")
    func compactJSONIsSettingsOnly() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let group = ConnectionGroup(name: "Production")
        try library.groups.addGroup(group)
        var connection = DatabaseConnection(name: "Orders", host: "db.example.com", port: 5_432, type: .postgresql)
        connection.groupId = group.id

        let json = ConnectionShareLink.compactJSON(for: connection, exporter: library.exporter)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["name"] as? String == "Orders")
        #expect(object["groupName"] == nil)
        #expect(object["groupRef"] == nil)
        #expect(object["ref"] == nil)
        #expect(!json.contains("\n"))
    }
}
