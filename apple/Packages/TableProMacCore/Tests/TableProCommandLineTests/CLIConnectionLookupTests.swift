import Foundation
@testable import TableProCommandLine
import TableProMCP
import TableProMCPTestSupport
import Testing

struct CLIConnectionLookupTests {
    private func sentConnection(_ rig: Rig) async throws -> String? {
        let request = try #require(await rig.requests(named: "execute_query").first)
        return try arguments(of: request)["connection_id"]?.stringValue
    }

    @Test("An id, in any case, resolves through list_connections")
    func byId() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], []))])
            #expect(await rig.run(["query", "-c", stagingId.lowercased(), "SELECT 1"]) == .success)
            #expect(await rig.server.requests.map { $0.header("Mcp-Name") } == ["list_connections", "execute_query"])
            #expect(try await sentConnection(rig) == stagingId)
        }
    }

    @Test("An exact name wins over one that differs only in case")
    func exactNameFirst() async throws {
        try await withRig { rig in
            let upper = UUID().uuidString
            await rig.route([
                "list_connections": try listing([(stagingId, "staging"), (upper, "Staging")]),
                "execute_query": try success(rows(["n"], []))
            ])
            #expect(await rig.run(["query", "-c", "Staging", "SELECT 1"]) == .success)
            #expect(try await sentConnection(rig) == upper)
        }
    }

    @Test("A name matches ignoring case when nothing matches exactly")
    func caseInsensitiveName() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], []))])
            #expect(await rig.run(["query", "-c", "STAGING", "SELECT 1"]) == .success)
            #expect(try await sentConnection(rig) == stagingId)
        }
    }

    @Test("A connection the listing leaves out exits 2 by name and by id")
    func hiddenOrUnknown() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try listing([])])
            #expect(await rig.run(["query", "-c", "Staging", "SELECT 1"]) == .usage)
            #expect(rig.console.errors.contains("No connection named \"Staging\""))
            #expect(await rig.run(["query", "-c", stagingId, "SELECT 1"]) == .usage)
            #expect(rig.console.errors.contains("with the id \(stagingId)"))
            #expect(await rig.requests(named: "execute_query").isEmpty)
        }
    }

    @Test("Two connections with the same name are a usage error that lists their ids")
    func ambiguousName() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try listing([("A", "Dev"), ("B", "Dev")])])
            #expect(await rig.run(["query", "-c", "Dev", "SELECT 1"]) == .usage)
            #expect(rig.console.errors.contains("A, B"))
            #expect(await rig.server.requests.count == 1)
        }
    }

    @Test("The browsing commands resolve the connection the same way")
    func browsingCommands() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "list_databases": try success(.object(["databases": .array([.string("app"), .string("postgres")])]))
            ])
            #expect(await rig.run(["databases", "-c", "staging", "--format", "csv"]) == .success)
            #expect(rig.console.output == "name\napp\npostgres\n")
            let request = try #require(await rig.requests(named: "list_databases").first)
            #expect(try arguments(of: request)["connection_id"]?.stringValue == stagingId)
        }
    }
}
