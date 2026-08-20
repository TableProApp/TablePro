import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("PromptsGetHandler")
struct PromptsHandlerTests {
    @Test("Handler declares prompts/get and the resources read scope")
    func metadata() {
        #expect(PromptsGetHandler.method == "prompts/get")
        #expect(PromptsGetHandler.requiredScopes == [.resourcesRead])
        #expect(PromptsGetHandler.isAvailableToLegacyClients)
    }

    @Test("A missing name is invalid params, not a missing method")
    func missingName() async throws {
        let error = try await failure(params: .object([:]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("An empty name is invalid params")
    func emptyName() async throws {
        let error = try await failure(params: .object(["name": .string("")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("An unknown prompt name answers -32602, never -32601")
    func unknownPromptIsInvalidParams() async throws {
        let error = try await failure(params: .object(["name": .string("no_such_prompt")]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.code != JsonRpcErrorCode.methodNotFound)
        #expect(error.message.contains("no_such_prompt"))
    }

    @Test("An argument the prompt does not declare is rejected by name")
    func unknownArgumentIsRejected() async throws {
        let error = try await failure(params: .object([
            "name": .string("explain_table"),
            "arguments": .object([
                MCPPromptArgument.connectionArgumentName: .string("primary"),
                "table": .string("orders"),
                "sortOrder": .string("asc")
            ])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.message.contains("sortOrder"))
    }

    @Test("A required argument that is absent is rejected before any schema read")
    func missingRequiredArgumentIsRejected() async throws {
        let error = try await failure(params: .object([
            "name": .string("explain_table"),
            "arguments": .object([MCPPromptArgument.connectionArgumentName: .string("primary")])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.message.contains("table"))
    }

    @Test("A required argument present only as whitespace is still missing")
    func blankRequiredArgumentIsRejected() async throws {
        let error = try await failure(params: .object([
            "name": .string("explain_table"),
            "arguments": .object([
                MCPPromptArgument.connectionArgumentName: .string("primary"),
                "table": .string("   ")
            ])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("An argument that is not a scalar is rejected")
    func structuredArgumentValueIsRejected() async throws {
        let error = try await failure(params: .object([
            "name": .string("explain_table"),
            "arguments": .object([
                MCPPromptArgument.connectionArgumentName: .string("primary"),
                "table": .array([.string("orders")])
            ])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.message.contains("table"))
    }

    @Test("An arguments value that is not an object is rejected")
    func nonObjectArgumentsAreRejected() async throws {
        let error = try await failure(params: .object([
            "name": .string("explain_table"),
            "arguments": .string("table=orders")
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A prompt never renders for a connection the principal may not read")
    func connectionAccessGatesRendering() async throws {
        let granted = UUID()
        let denied = UUID()
        let principal = MCPProtocolTestSupport.makePrincipal(
            scopes: MCPScope.readOnlySet,
            connectionAccess: .limited([granted])
        )
        let error = try await failure(
            params: .object([
                "name": .string("explain_table"),
                "arguments": .object([
                    MCPPromptArgument.connectionArgumentName: .string(denied.uuidString),
                    "table": .string("orders")
                ])
            ]),
            principal: principal
        )
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.message.contains("no database connection"))
    }

    @Test("A cancelled request never reaches the renderer")
    func cancellationIsHonoured() async throws {
        let handler = PromptsGetHandler(services: MCPProtocolHandlerTestSupport.makeToolServices())
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: PromptsGetHandler.method,
            principal: MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
        )
        await context.cancellation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await handler.handle(
                params: .object([
                    "name": .string("explain_table"),
                    "arguments": .object([
                        MCPPromptArgument.connectionArgumentName: .string("primary"),
                        "table": .string("orders")
                    ])
                ]),
                context: context
            )
        }
    }

    private func failure(
        params: JsonValue?,
        principal: MCPPrincipal = MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
    ) async throws -> MCPProtocolError {
        let handler = PromptsGetHandler(services: MCPProtocolHandlerTestSupport.makeToolServices())
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: PromptsGetHandler.method,
            principal: principal
        )
        do {
            let result = try await handler.handle(params: params, context: context)
            Issue.record("Expected an MCPProtocolError, got \(result)")
            throw PromptHandlerTestError.unexpectedSuccess
        } catch let error as MCPProtocolError {
            return error
        }
    }
}

@Suite("MCPPromptSchemaReader connection resolution")
struct MCPPromptSchemaReaderTests {
    private static let alpha = MCPConnectionDescriptor(
        id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001") ?? UUID(),
        name: "Alpha",
        databaseType: "PostgreSQL",
        database: "app",
        isConnected: true,
        safeMode: "off"
    )
    private static let beta = MCPConnectionDescriptor(
        id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002") ?? UUID(),
        name: "Beta",
        databaseType: "MySQL",
        database: "shop",
        isConnected: false,
        safeMode: "restricted"
    )

    @Test("A connection resolves by name, case-insensitively")
    func resolvesByName() async throws {
        let reader = makeReader(connections: [Self.alpha, Self.beta])
        let resolved = try await reader.resolveConnection(
            reference: "alpha",
            principal: MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
        )
        #expect(resolved.id == Self.alpha.id)
    }

    @Test("A connection resolves by UUID")
    func resolvesByIdentifier() async throws {
        let reader = makeReader(connections: [Self.alpha, Self.beta])
        let resolved = try await reader.resolveConnection(
            reference: Self.beta.id.uuidString,
            principal: MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
        )
        #expect(resolved.id == Self.beta.id)
    }

    @Test("An unknown reference lists what is available instead of guessing")
    func unknownReferenceListsAlternatives() async throws {
        let reader = makeReader(connections: [Self.alpha, Self.beta])
        let error = await protocolError {
            _ = try await reader.resolveConnection(
                reference: "Gamma",
                principal: MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
            )
        }
        #expect(error?.code == JsonRpcErrorCode.invalidParams)
        #expect(error?.message.contains("Alpha") == true)
        #expect(error?.message.contains("Beta") == true)
    }

    @Test("An ambiguous name asks for a UUID rather than picking one")
    func ambiguousNameIsRefused() async throws {
        let duplicate = MCPConnectionDescriptor(
            id: UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003") ?? UUID(),
            name: "Alpha",
            databaseType: "SQLite",
            database: "local",
            isConnected: false,
            safeMode: "off"
        )
        let reader = makeReader(connections: [Self.alpha, duplicate])
        let error = await protocolError {
            _ = try await reader.resolveConnection(
                reference: "Alpha",
                principal: MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
            )
        }
        #expect(error?.code == JsonRpcErrorCode.invalidParams)
        #expect(error?.message.contains(Self.alpha.id.uuidString) == true)
        #expect(error?.message.contains(duplicate.id.uuidString) == true)
    }

    @Test("A principal with no readable connection is told so, not handed a name")
    func noReadableConnection() async throws {
        let reader = makeReader(connections: [])
        let error = await protocolError {
            _ = try await reader.resolveConnection(
                reference: Self.alpha.id.uuidString,
                principal: MCPProtocolTestSupport.makePrincipal(
                    scopes: MCPScope.readOnlySet,
                    connectionAccess: .limited([])
                )
            )
        }
        #expect(error?.code == JsonRpcErrorCode.invalidParams)
        #expect(error?.message.contains(Self.alpha.name) == false)
    }

    private func makeReader(connections: [MCPConnectionDescriptor]) -> MCPPromptSchemaReader {
        MCPPromptSchemaReader(
            services: MCPProtocolHandlerTestSupport.makeToolServices(),
            source: FixedPromptSchemaSource(connections: connections)
        )
    }

    private func protocolError(_ body: () async throws -> Void) async -> MCPProtocolError? {
        do {
            try await body()
            return nil
        } catch let error as MCPProtocolError {
            return error
        } catch {
            return nil
        }
    }
}

enum PromptHandlerTestError: Error {
    case unexpectedSuccess
}

struct FixedPromptSchemaSource: MCPCompletionSchemaSource {
    let connections: [MCPConnectionDescriptor]

    func connections(principal: MCPPrincipal) async -> [MCPConnectionDescriptor] {
        connections.filter { principal.connectionAccess.allows($0.id) }
    }

    func databases(connectionId: UUID) async -> [String] { [] }
    func schemas(connectionId: UUID, database: String?) async -> [String] { [] }
    func tables(connectionId: UUID, database: String?, schema: String?) async -> [String] { [] }
}
