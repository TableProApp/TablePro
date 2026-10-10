import Foundation
import Testing

@testable import TableProImport

@Suite("Exported icons")
struct ExportableIconTests {
    private typealias Fixtures = ImportFixtures

    private func connection(iconName: String?) -> ExportableConnection {
        ExportableConnection(
            name: "Prod", host: "db.example.com", port: 5_432, database: "app", username: "admin",
            type: "PostgreSQL", color: "Red", iconName: iconName, startupCommands: "SET x = 1"
        )
    }

    private func bundle(connectionIcon: String?, groupIcon: String? = nil) throws -> ConnectionBundle {
        try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: connection(iconName: connectionIcon), groupRef: "g1")],
            groups: [BundleGroup(ref: "g1", name: "Clients", color: "Red", iconName: groupIcon)]
        )
    }

    private func roundTripped(_ bundle: ConnectionBundle) throws -> ConnectionBundle {
        try ConnectionBundleCodec.decode(ConnectionBundleCodec.encode(bundle))
    }

    private func decodedV1(_ json: String) throws -> ConnectionBundle {
        try ConnectionBundleCodec.decode(Data(json.utf8))
    }

    @Test("A file written before icons existed decodes with no icon")
    func olderFileDecodesWithoutIcon() throws {
        let decoded = try decodedV1(
            """
            {"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","appVersion":"0.1",\
            "connections":[{"name":"Legacy","host":"localhost","port":3306,\
            "database":"","username":"","type":"MySQL","color":"Blue","groupName":"Clients"}],\
            "groups":[{"name":"Clients","color":"Red"}]}
            """
        )

        #expect(decoded.connections.first?.settings.iconName == nil)
        #expect(decoded.connections.first?.settings.color == "Blue")
        #expect(decoded.groups.first?.iconName == nil)
        #expect(decoded.groups.first?.color == "Red")
    }

    @Test("A format 1 file carrying icons upgrades with them")
    func versionOneIconsUpgrade() throws {
        let decoded = try decodedV1(
            """
            {"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","appVersion":"0.69",\
            "connections":[{"name":"Prod","host":"db","port":5432,"database":"","username":"",\
            "type":"PostgreSQL","iconName":"server.rack","groupName":"clients"}],\
            "groups":[{"name":"Clients","color":"Purple","iconName":"briefcase"},\
            {"name":"clients","color":"Red","iconName":"flame"}]}
            """
        )

        let chain = decoded.groupChain(decoded.connections.first?.groupRef)
        let group = try #require(chain.first)
        #expect(decoded.connections.first?.settings.iconName == "server.rack")
        #expect(group.color == "Purple")
        #expect(group.iconName == "briefcase")
    }

    @Test("A malformed icon in a format 1 file is dropped")
    func versionOneJunkIconsAreDropped() throws {
        let decoded = try decodedV1(
            """
            {"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","appVersion":"0.69",\
            "connections":[{"name":"Prod","host":"db","port":5432,"database":"","username":"",\
            "type":"PostgreSQL","iconName":"Server Rack!","groupName":"Clients"}],\
            "groups":[{"name":"Clients","iconName":"../../etc"}]}
            """
        )

        #expect(decoded.connections.first?.settings.iconName == nil)
        #expect(decoded.groups.first?.iconName == nil)
    }

    @Test("A connection icon and a group icon survive the file round trip")
    func iconsRoundTrip() throws {
        let decoded = try roundTripped(bundle(connectionIcon: "server.rack", groupIcon: "briefcase"))

        #expect(decoded.connections.first?.settings.iconName == "server.rack")
        #expect(decoded.groups.first?.iconName == "briefcase")
        #expect(decoded.groups.first?.color == "Red")
    }

    @Test("A connection or group with no icon writes no icon key")
    func noIconWritesNoKey() throws {
        let data = try ConnectionBundleCodec.encode(bundle(connectionIcon: nil))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("iconName"))
    }

    @Test(
        "An icon name that is not shaped like an SF Symbol is dropped on import",
        arguments: ["", "  ", "Server.Rack", "../../etc/passwd", "a..b", "rm -rf", String(repeating: "a", count: 101)]
    )
    func junkIconIsDropped(_ raw: String) throws {
        let decoded = try roundTripped(bundle(connectionIcon: raw, groupIcon: raw))

        #expect(decoded.connections.first?.settings.iconName == nil)
        #expect(decoded.groups.first?.iconName == nil)
    }

    @Test("Import trims an icon name and keeps a well-formed one it does not know")
    func importNormalizesIcon() {
        #expect(connection(iconName: " server.rack\n").sanitizedForImport().iconName == "server.rack")
        #expect(connection(iconName: "made.up.symbol").sanitizedForImport().iconName == "made.up.symbol")
    }

    @Test("Every copy of an exported connection keeps its icon")
    func copiesKeepIcon() throws {
        let original = connection(iconName: "flame")
        var renamed = original
        renamed.name = "Renamed"
        let replaced = try #require(try bundle(connectionIcon: "flame").replacingSettings(renamed, of: "c1").connection("c1"))
        let copies = [
            original.withoutStartupCommands(),
            original.withoutTunnelCommand(),
            original.sanitizedForImport(),
            replaced.settings
        ]

        #expect(copies.allSatisfy { $0.iconName == "flame" })
        #expect(copies.allSatisfy { $0.color == "Red" })
    }

    @Test("A bundle group round-trips its name, colour and icon")
    func groupRoundTrips() throws {
        let group = BundleGroup(ref: "g1", name: "Clients", color: "Purple", iconName: "person.3")

        let decoded = try JSONDecoder().decode(BundleGroup.self, from: JSONEncoder().encode(group))

        #expect(decoded == group)
    }

    @Test("The builder keeps the first icon a group path brings")
    func builderKeepsFirstGroupIcon() throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(
            Fixtures.settings(name: "One"),
            ref: "c1",
            groupPath: [.init(name: "Clients"), .init(name: "Prod", iconName: "flame")]
        )
        builder.addConnection(
            Fixtures.settings(name: "Two"),
            ref: "c2",
            groupPath: [.init(name: "clients", iconName: "briefcase"), .init(name: "prod", iconName: "leaf")]
        )

        let built = try builder.build()

        #expect(built.groups.map(\.name) == ["Clients", "Prod"])
        #expect(built.groups.map(\.iconName) == ["briefcase", "flame"])
    }

    @Test("An export carries each group's icon along the connection's chain")
    func exportCarriesGroupIcons() throws {
        let clientId = UUID()
        let prodId = UUID()
        let connectionId = UUID()
        let input = BundleExportInput(
            connections: [
                BundleExportInput.Connection(
                    id: connectionId,
                    settings: connection(iconName: "server.rack"),
                    groupId: prodId
                )
            ],
            groups: [
                BundleExportInput.Group(id: clientId, name: "Client A", iconName: "briefcase"),
                BundleExportInput.Group(id: prodId, name: "Prod", color: "Red", parentId: clientId)
            ]
        )

        let exported = try BundleExportAssembler.assemble(input, options: .connectionsOnly, appVersion: "Tests")
        let chain = exported.groupChain(exported.connection("c1")?.groupRef)

        #expect(exported.connection("c1")?.settings.iconName == "server.rack")
        #expect(chain.map(\.name) == ["Client A", "Prod"])
        #expect(chain.map(\.iconName) == ["briefcase", nil])
        #expect(chain.map(\.color) == [nil, "Red"])
    }

    @Test("A planned group path carries each group's icon")
    func plannedGroupPathCarriesIcons() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(), groupRef: "g2")],
            groups: [
                BundleGroup(ref: "g1", name: "Client A", iconName: "briefcase"),
                BundleGroup(ref: "g2", name: "Prod", color: "Red", parentRef: "g1")
            ]
        )
        let preview = Fixtures.makePreview(bundle)
        var ids = SequentialIds()

        let plan = ImportPlanner.plan(preview, selection: .defaults(for: preview), ids: &ids)

        #expect(plan.connections.first?.groupPath == [
            PathComponent(name: "Client A", scope: nil, color: nil, iconName: "briefcase"),
            PathComponent(name: "Prod", scope: nil, color: "Red")
        ])
    }

    @Test("Only a group the import creates takes the file's icon")
    func iconAppliesOnlyToCreatedGroups() {
        let existing = PathNode(id: UUID(), name: "Clients", parentId: nil, scope: nil)

        let result = PathTreeResolver.resolve(
            [[
                PathComponent(name: "clients", scope: nil, color: "Red", iconName: "flame"),
                PathComponent(name: "Prod", scope: nil, color: nil, iconName: "server.rack")
            ]],
            existing: [existing],
            makeId: { Fixtures.uuid(1) }
        )

        #expect(result.created == [
            PathNode(id: Fixtures.uuid(1), name: "Prod", parentId: existing.id, scope: nil, iconName: "server.rack")
        ])
        #expect(result.leaves == [Fixtures.uuid(1)])
    }
}
