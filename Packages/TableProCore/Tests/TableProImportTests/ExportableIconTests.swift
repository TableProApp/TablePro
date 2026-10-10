import Foundation
@testable import TableProImport
import Testing

@Suite("Exported icons")
struct ExportableIconTests {
    private func connection(iconName: String?) -> ExportableConnection {
        ExportableConnection(
            name: "Prod", host: "db.example.com", port: 5_432, database: "app", username: "admin",
            type: "PostgreSQL", sshConfig: nil, sslConfig: nil, color: "Red", iconName: iconName,
            tagName: nil, groupName: "Clients", sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil,
            additionalFields: nil, redisDatabase: nil, startupCommands: "SET x = 1", localOnly: nil
        )
    }

    private func envelope(
        connections: [ExportableConnection],
        groups: [ExportableGroup]? = nil
    ) -> ConnectionExportEnvelope {
        ConnectionExportEnvelope(
            formatVersion: 1, exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
            connections: connections, groups: groups, tags: nil, credentials: nil
        )
    }

    @Test("A file written before icons existed decodes with no icon")
    func olderFileDecodesWithoutIcon() throws {
        let json = Data(
            """
            {"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","appVersion":"0.1",\
            "connections":[{"name":"Legacy","host":"localhost","port":3306,\
            "database":"","username":"","type":"MySQL","color":"Blue"}],\
            "groups":[{"name":"Clients","color":"Red"}]}
            """.utf8
        )

        let decoded = try ConnectionImportDecoder.decodeData(json)

        #expect(decoded.connections.first?.iconName == nil)
        #expect(decoded.connections.first?.color == "Blue")
        #expect(decoded.groups?.first?.iconName == nil)
        #expect(decoded.groups?.first?.color == "Red")
    }

    @Test("A connection icon and a group icon survive the file round trip")
    func iconsRoundTrip() throws {
        let file = envelope(
            connections: [connection(iconName: "server.rack")],
            groups: [ExportableGroup(name: "Clients", color: "Red", iconName: "briefcase")]
        )

        let decoded = try ConnectionImportDecoder.decodeData(ConnectionImportDecoder.encode(file))

        #expect(decoded.connections.first?.iconName == "server.rack")
        #expect(decoded.groups?.first?.iconName == "briefcase")
        #expect(decoded.groups?.first?.color == "Red")
    }

    @Test("A connection with no icon writes no icon key")
    func noIconWritesNoKey() throws {
        let data = try ConnectionImportDecoder.encode(envelope(connections: [connection(iconName: nil)]))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("iconName"))
    }

    @Test(
        "An icon name that is not shaped like an SF Symbol is dropped on import",
        arguments: ["", "  ", "Server.Rack", "../../etc/passwd", "a..b", "rm -rf", String(repeating: "a", count: 101)]
    )
    func junkIconIsDropped(_ raw: String) throws {
        let file = envelope(connections: [connection(iconName: raw)])

        let decoded = try ConnectionImportDecoder.decodeData(ConnectionImportDecoder.encode(file))

        #expect(decoded.connections.first?.iconName == nil)
    }

    @Test("Import trims an icon name and keeps a well-formed one it does not know")
    func importNormalizesIcon() {
        #expect(connection(iconName: " server.rack\n").sanitizedForImport().iconName == "server.rack")
        #expect(connection(iconName: "made.up.symbol").sanitizedForImport().iconName == "made.up.symbol")
    }

    @Test("Every copy of an exported connection keeps its icon")
    func copiesKeepIcon() {
        let original = connection(iconName: "flame")
        let copies = [
            original.retyped(to: "MySQL"),
            original.renamed(to: "Renamed"),
            original.withoutStartupCommands(),
            original.withoutTunnelCommand(),
            original.sanitizedForImport()
        ]

        #expect(copies.allSatisfy { $0.iconName == "flame" })
        #expect(copies.allSatisfy { $0.color == "Red" })
    }

    @Test("An exported group round-trips its name, colour and icon")
    func groupRoundTrips() throws {
        let group = ExportableGroup(name: "Clients", color: "Purple", iconName: "person.3")

        let decoded = try JSONDecoder().decode(ExportableGroup.self, from: JSONEncoder().encode(group))

        #expect(decoded.name == "Clients")
        #expect(decoded.color == "Purple")
        #expect(decoded.iconName == "person.3")
    }
}
