import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ToolsListHandler")
struct ToolsListHandlerTests {
    @Test("The handler answers tools/list and requires the tools read scope")
    func methodAndScopes() {
        #expect(ToolsListHandler.method == "tools/list")
        #expect(ToolsListHandler.requiredScopes == [.toolsRead])
        #expect(ToolsListHandler.isAvailableToLegacyClients)
    }

    @Test("The listing is exactly the tools the principal's scopes allow")
    func listingMatchesTheRegistryForTheseScopes() async throws {
        let scopes: Set<MCPScope> = [.toolsRead, .toolsWrite]
        let payload = try await runToolsList(scopes: scopes)
        let names = try #require(payload["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        let expected = MCPToolRegistry.tools(for: scopes).map { type(of: $0).name }

        #expect(Set(names) == Set(expected))
        #expect(names.count == expected.count)
    }

    @Test("A read-only principal never sees a tool that needs the write scope")
    func readOnlyPrincipalSeesFewerTools() async throws {
        let readOnly = try await names(for: [.toolsRead])
        let readWrite = try await names(for: [.toolsRead, .toolsWrite])

        #expect(readOnly.contains("list_connections"))
        #expect(readOnly.contains("connect") == false)
        #expect(readWrite.contains("connect"))
        #expect(readOnly.count < readWrite.count)
        #expect(Set(readOnly).isSubset(of: Set(readWrite)))
    }

    @Test("A principal with no scopes sees no tools at all")
    func noScopesListsNothing() async throws {
        let payload = try await runToolsList(scopes: [])
        #expect(payload["tools"]?.arrayValue?.isEmpty == true)
        #expect(payload["nextCursor"] == nil)
    }

    @Test("Tools are listed in a stable name order")
    func toolsAreSortedByName() async throws {
        let listed = try await names(for: [.toolsRead, .toolsWrite])
        #expect(listed == listed.sorted())
    }

    @Test("Every descriptor carries a name, a description and a JSON Schema input")
    func descriptorShape() async throws {
        let payload = try await runToolsList(scopes: [.toolsRead, .toolsWrite])
        let tools = try #require(payload["tools"]?.arrayValue)
        #expect(tools.isEmpty == false)

        for tool in tools {
            let name = try #require(tool["name"]?.stringValue)
            #expect(name.isEmpty == false)
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            let schema = try #require(tool["inputSchema"]?.objectValue)
            #expect(schema["type"]?.stringValue == "object")
            #expect(schema["additionalProperties"]?.boolValue != nil)
            if let properties = schema["properties"] {
                #expect(properties.objectValue != nil, "\(name) declares a non-object properties block")
            }
        }
    }

    @Test("Annotations describe the behaviour of every tool")
    func annotationsAreComplete() async throws {
        let payload = try await runToolsList(scopes: [.toolsRead, .toolsWrite])
        let tools = try #require(payload["tools"]?.arrayValue)

        for tool in tools {
            let name = tool["name"]?.stringValue ?? "?"
            let annotations = try #require(tool["annotations"]?.objectValue, "missing annotations for \(name)")
            #expect(annotations["title"]?.stringValue?.isEmpty == false)
            #expect(annotations["readOnlyHint"]?.boolValue != nil)
            #expect(annotations["destructiveHint"]?.boolValue != nil)
        }
    }

    @Test("The listing is cacheable for the calling principal only")
    func cacheHintIsPrivate() async throws {
        let result = try await run(scopes: [.toolsRead])
        let hint = try #require(result.cacheHint)
        #expect(hint.scope == .privateScope)
        #expect(hint.ttlMilliseconds == 300_000)
        #expect(result.kind == .complete)
    }

    @Test("A short listing carries no continuation cursor")
    func noCursorForASinglePage() async throws {
        let payload = try await runToolsList(scopes: [.toolsRead, .toolsWrite])
        let count = payload["tools"]?.arrayValue?.count ?? 0
        #expect(count <= MCPListPagination.defaultPageSize)
        #expect(payload["nextCursor"] == nil)
    }

    @Test("A cursor resumes the listing where the previous page stopped")
    func cursorResumesTheListing() async throws {
        let all = try await names(for: [.toolsRead, .toolsWrite])
        let cursor = MCPListPagination.encodeCursor(offset: 5, method: ToolsListHandler.method)
        let payload = try await runToolsList(
            scopes: [.toolsRead, .toolsWrite],
            params: .object(["cursor": .string(cursor)])
        )
        let resumed = try #require(payload["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(resumed == Array(all.dropFirst(5)))
    }

    @Test("A cursor minted for another method is refused")
    func cursorFromAnotherMethodIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 0, method: "resources/list")
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A cursor past the end of the listing is refused")
    func cursorPastTheEndIsRefused() async throws {
        let cursor = MCPListPagination.encodeCursor(offset: 9_999, method: ToolsListHandler.method)
        let error = try await failure(params: .object(["cursor": .string(cursor)]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A cursor that is not a non-empty string is refused")
    func malformedCursorIsRefused() async throws {
        for value in [JsonValue.string(""), .int(3), .bool(true), .object([:])] {
            let error = try await failure(params: .object(["cursor": value]))
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("A null cursor is treated as no cursor")
    func nullCursorIsIgnored() async throws {
        let payload = try await runToolsList(
            scopes: [.toolsRead],
            params: .object(["cursor": .null])
        )
        #expect(payload["tools"]?.arrayValue?.isEmpty == false)
    }

    private func run(scopes: Set<MCPScope>, params: JsonValue? = nil) async throws -> MCPResult {
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: ToolsListHandler.method,
            params: params,
            principalScopes: scopes
        )
        return try await ToolsListHandler().handle(params: params, context: context)
    }

    private func runToolsList(scopes: Set<MCPScope>, params: JsonValue? = nil) async throws -> JsonValue {
        let result = try await run(scopes: scopes, params: params)
        return .object(result.payload)
    }

    private func names(for scopes: Set<MCPScope>) async throws -> [String] {
        let payload = try await runToolsList(scopes: scopes)
        return payload["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    private func failure(params: JsonValue?) async throws -> MCPProtocolError {
        do {
            _ = try await run(scopes: [.toolsRead, .toolsWrite], params: params)
        } catch let error as MCPProtocolError {
            return error
        }
        Issue.record("expected the handler to refuse the request")
        return .internalError(detail: "unreachable")
    }
}
