//
//  MCPConnectionListEncoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct MCPConnectionListEncoderTests {
    private func listing(
        id: UUID = UUID(),
        name: String = "Acme",
        color: ConnectionColor = .none,
        group: ExternalConnectionListing.Group? = nil,
        tags: [ExternalConnectionListing.Tag] = [],
        aiPolicy: AIConnectionPolicy = .askEachTime
    ) -> ExternalConnectionListing {
        ExternalConnectionListing(
            id: id,
            name: name,
            databaseType: "PostgreSQL",
            host: "db.acme.io",
            port: 5_432,
            username: "app_ro",
            database: "app",
            schema: "public",
            isConnected: true,
            color: color,
            group: group,
            tags: tags,
            aiPolicy: aiPolicy,
            externalAccess: .readOnly,
            safeModeLevel: .alert
        )
    }

    private func entries(
        _ listings: [ExternalConnectionListing],
        access: ConnectionAccess = .all,
        purpose: MCPConnectionListPurpose = .agent
    ) throws -> [[String: JsonValue]] {
        let payload = MCPConnectionListEncoder.encode(listings, access: access, purpose: purpose)
        let array = try #require(payload["connections"]?.arrayValue)
        return try array.map { try #require($0.objectValue) }
    }

    @Test("The fields that existed before keep their names and values")
    func existingFields() throws {
        let item = listing()
        let entry = try #require(try entries([item]).first)

        #expect(entry["id"] == .string(item.id.uuidString))
        #expect(entry["name"] == .string("Acme"))
        #expect(entry["type"] == .string("PostgreSQL"))
        #expect(entry["host"] == .string("db.acme.io"))
        #expect(entry["port"] == .int(5_432))
        #expect(entry["database"] == .string("app"))
        #expect(entry["is_connected"] == .bool(true))
        #expect(entry["ai_policy"] == .string("askEachTime"))
        #expect(entry["external_access"] == .string("readOnly"))
        #expect(entry["safe_mode"] == .string(SafeModeLevel.alert.rawValue))
    }

    @Test("No user name, schema or credential reaches the entry")
    func noExtraFields() throws {
        let entry = try #require(try entries([listing()]).first)
        let allowed: Set<String> = [
            "id", "name", "type", "host", "port", "database", "is_connected",
            "ai_policy", "external_access", "safe_mode", "color", "group", "tags"
        ]
        #expect(Set(entry.keys).isSubset(of: allowed))
        #expect(entry["username"] == nil)
    }

    @Test("A connection with no color has no color field")
    func noColor() throws {
        let entry = try #require(try entries([listing(color: .none)]).first)
        #expect(entry["color"] == nil)
    }

    @Test("Colors are written as lowercase names")
    func colorNames() throws {
        let encoded = try entries(ConnectionColor.allCases.map { listing(color: $0) })
            .map { $0["color"]?.stringValue }
        #expect(encoded == [nil, "red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"])
    }

    @Test("A connection in no group has no group field")
    func noGroup() throws {
        let entry = try #require(try entries([listing(group: nil)]).first)
        #expect(entry["group"] == nil)
    }

    @Test("A group carries its id, name, path and color")
    func groupFields() throws {
        let groupId = UUID()
        let group = ExternalConnectionListing.Group(id: groupId, name: "Acme", path: ["Clients", "Acme"], color: .blue)

        let entry = try #require(try entries([listing(group: group)]).first)

        #expect(entry["group"] == .object([
            "id": .string(groupId.uuidString),
            "name": .string("Acme"),
            "path": .array([.string("Clients"), .string("Acme")]),
            "color": .string("blue")
        ]))
    }

    @Test("A group with no color has no color field")
    func groupWithoutColor() throws {
        let group = ExternalConnectionListing.Group(id: UUID(), name: "Local", path: ["Local"], color: .none)
        let entry = try #require(try entries([listing(group: group)]).first)
        #expect(entry["group"]?["color"] == nil)
        #expect(entry["group"]?["path"] == .array([.string("Local")]))
    }

    @Test("Tags are always present, and empty when the connection has none")
    func tagsAlwaysPresent() throws {
        let entry = try #require(try entries([listing(tags: [])]).first)
        #expect(entry["tags"] == .array([]))
    }

    @Test("Tags keep their order, and a tag with no color has no color field")
    func tagFields() throws {
        let first = ExternalConnectionListing.Tag(id: UUID(), name: "production", color: .red)
        let second = ExternalConnectionListing.Tag(id: UUID(), name: "reporting", color: .none)

        let entry = try #require(try entries([listing(tags: [first, second])]).first)

        #expect(entry["tags"] == .array([
            .object(["id": .string(first.id.uuidString), "name": .string("production"), "color": .string("red")]),
            .object(["id": .string(second.id.uuidString), "name": .string("reporting")])
        ]))
    }

    @Test("A connection with AI policy Never is left out")
    func aiNeverIsHidden() throws {
        let visible = listing(name: "A", aiPolicy: .alwaysAllow)
        let hidden = listing(name: "B", aiPolicy: .never)

        let ids = try entries([visible, hidden]).compactMap { $0["id"]?.stringValue }

        #expect(ids == [visible.id.uuidString])
    }

    @Test("Only connections on the token's allowlist are listed, in the order given")
    func allowlist() throws {
        let first = listing(name: "A")
        let second = listing(name: "B")
        let third = listing(name: "C")

        let all = try entries([first, second, third]).compactMap { $0["name"]?.stringValue }
        let limited = try entries([first, second, third], access: .limited([third.id, first.id]))
            .compactMap { $0["name"]?.stringValue }
        let none = try entries([first, second, third], access: .limited([]))

        #expect(all == ["A", "B", "C"])
        #expect(limited == ["A", "C"])
        #expect(none.isEmpty)
    }

    @Test("The display listing keeps connections hidden from AI, the agent listing does not")
    func displayKeepsHiddenConnections() throws {
        let visible = listing(name: "A", aiPolicy: .alwaysAllow)
        let hidden = listing(name: "B", aiPolicy: .never)

        let agent = try entries([visible, hidden]).compactMap { $0["name"]?.stringValue }
        let display = try entries([visible, hidden], purpose: .display).compactMap { $0["name"]?.stringValue }

        #expect(agent == ["A"])
        #expect(display == ["A", "B"])
    }

    @Test("The display listing still honors the token's allowlist")
    func displayKeepsTheAllowlist() throws {
        let allowed = listing(name: "A", aiPolicy: .never)
        let outside = listing(name: "B", aiPolicy: .never)

        let names = try entries([allowed, outside], access: .limited([allowed.id]), purpose: .display)
            .compactMap { $0["name"]?.stringValue }
        let none = try entries([allowed, outside], access: .limited([]), purpose: .display)

        #expect(names == ["A"])
        #expect(none.isEmpty)
    }

    @Test("A display entry carries the labels and the user name, and none of the policy fields")
    func displayEntryFields() throws {
        let group = ExternalConnectionListing.Group(id: UUID(), name: "Acme", path: ["Acme"], color: .red)
        let tag = ExternalConnectionListing.Tag(id: UUID(), name: "production", color: .red)
        let item = listing(color: .blue, group: group, tags: [tag], aiPolicy: .never)

        let entry = try #require(try entries([item], purpose: .display).first)

        #expect(Set(entry.keys) == [
            "id", "name", "type", "host", "port", "database", "is_connected",
            "color", "group", "tags", "username"
        ])
        #expect(entry["username"] == .string("app_ro"))
        #expect(entry["ai_policy"] == nil)
        #expect(entry["external_access"] == nil)
        #expect(entry["safe_mode"] == nil)
    }

    @Test("The agent listing is the default and never carries a user name")
    func agentIsTheDefault() throws {
        let items = [listing(name: "A"), listing(name: "B", aiPolicy: .never)]
        let implicit = MCPConnectionListEncoder.encode(items, access: .all)
        let explicit = MCPConnectionListEncoder.encode(items, access: .all, purpose: .agent)

        #expect(implicit == explicit)
        let connections = try #require(implicit["connections"]?.arrayValue)
        for entry in connections {
            #expect(entry["username"] == nil)
        }
    }
}
