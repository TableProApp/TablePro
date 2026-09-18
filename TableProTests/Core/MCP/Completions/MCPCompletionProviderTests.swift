import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCPCompletionProvider")
struct MCPCompletionProviderTests {
    @Test("Completing a prompt connection argument offers the readable connection names")
    func completesConnectionNames() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_schema"),
            argumentName: MCPPromptArgument.connectionArgumentName,
            argumentValue: "",
            context: [:],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values == ["Analytics", "Billing"])
        #expect(result.total == 2)
        #expect(!result.hasMore)
    }

    @Test("Two connections sharing a name are offered by identifier so the choice stays unambiguous")
    func duplicateNamesFallBackToIdentifiers() async {
        let twin = MCPConnectionDescriptor(
            id: CompletionFixtures.thirdId,
            name: "Analytics",
            databaseType: "MySQL",
            database: "warehouse",
            isConnected: false,
            safeMode: "off"
        )
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections + [twin])
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_schema"),
            argumentName: MCPPromptArgument.connectionArgumentName,
            argumentValue: "",
            context: [:],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values.contains(CompletionFixtures.analyticsId.uuidString))
        #expect(result.values.contains(CompletionFixtures.thirdId.uuidString))
        #expect(!result.values.contains("Analytics"))
        #expect(result.values.contains("Billing"))
    }

    @Test("Completing a table reads the connection, database, and schema already resolved in context")
    func tableCompletionUsesResolvedContext() async throws {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders", "orderItems", "customers"])
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "order",
            context: ["connection": "Analytics", "database": "warehouse", "schema": "public"],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values == ["orderItems", "orders"])

        let call = try #require(await source.tableCalls.first)
        #expect(call.connectionId == CompletionFixtures.analyticsId)
        #expect(call.database == "warehouse")
        #expect(call.schema == "public")
    }

    @Test("A table completion with no connection in context asks the source for nothing")
    func tableCompletionWithoutConnectionYieldsNothing() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders"])
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: [:],
            principal: CompletionFixtures.principal()
        )

        let calls = await source.tableCalls
        #expect(result.values.isEmpty)
        #expect(calls.isEmpty)
    }

    @Test("A resource template resolves its variables from the URI itself")
    func templateVariablesComeFromTheUri() async throws {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders"])
        let provider = MCPCompletionProvider(source: source)

        let uri = "tablepro://connections/\(CompletionFixtures.billingId.uuidString)/tables"
            + "?database=shop&schema=sales"
        let result = await provider.complete(
            reference: .resourceTemplate(uri: uri),
            argumentName: "table",
            argumentValue: "",
            context: [:],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values == ["orders"])
        let call = try #require(await source.tableCalls.first)
        #expect(call.connectionId == CompletionFixtures.billingId)
        #expect(call.database == "shop")
        #expect(call.schema == "sales")
    }

    @Test("An explicit context value wins over the one the URI implies")
    func explicitContextOverridesTheUri() async throws {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setSchemas(["reporting"])
        let provider = MCPCompletionProvider(source: source)

        let uri = "tablepro://connections/\(CompletionFixtures.billingId.uuidString)/schemas?database=shop"
        _ = await provider.complete(
            reference: .resourceTemplate(uri: uri),
            argumentName: "schema",
            argumentValue: "",
            context: ["database": "warehouse"],
            principal: CompletionFixtures.principal()
        )

        let call = try #require(await source.schemaCalls.first)
        #expect(call.database == "warehouse")
    }

    @Test("A completion never exceeds one hundred values and says there are more")
    func capsAtOneHundredValues() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables((0 ..< 150).map { String(format: "table_%03d", $0) })
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: ["connection": "Analytics"],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values.count == MCPCompletionResult.maximumValues)
        #expect(result.total == 150)
        #expect(result.hasMore)
    }

    @Test("A completion that fits reports no more values")
    func shortResultHasNoMore() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders", "customers"])
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: ["connection": "Analytics"],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values == ["customers", "orders"])
        #expect(result.total == 2)
        #expect(!result.hasMore)
    }

    @Test("Prefix matches rank ahead of substring matches")
    func prefixMatchesRankFirst() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["customerOrders", "orders", "orderItems"])
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "order",
            context: ["connection": "Analytics"],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values == ["orderItems", "orders", "customerOrders"])
    }

    @Test("A connection outside the grant is never offered, by name or by identifier")
    func connectionsOutsideTheGrantAreNeverOffered() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        let provider = MCPCompletionProvider(source: source)
        let principal = CompletionFixtures.principal(
            connectionAccess: .limited([CompletionFixtures.analyticsId])
        )

        let byName = await provider.complete(
            reference: .prompt(name: "explain_schema"),
            argumentName: MCPPromptArgument.connectionArgumentName,
            argumentValue: "",
            context: [:],
            principal: principal
        )
        #expect(byName.values == ["Analytics"])

        let byIdentifier = await provider.complete(
            reference: .prompt(name: "explain_schema"),
            argumentName: MCPPromptArgument.connectionArgumentName,
            argumentValue: CompletionFixtures.billingId.uuidString,
            context: [:],
            principal: principal
        )
        #expect(byIdentifier.values.isEmpty)
    }

    @Test("A table completion aimed at a connection outside the grant returns nothing")
    func tableCompletionRespectsTheGrant() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders"])
        let provider = MCPCompletionProvider(source: source)

        let result = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: ["connection_id": CompletionFixtures.billingId.uuidString],
            principal: CompletionFixtures.principal(
                connectionAccess: .limited([CompletionFixtures.analyticsId])
            )
        )

        let calls = await source.tableCalls
        #expect(result.values.isEmpty)
        #expect(calls.isEmpty)
    }

    @Test("An unmatched connection name falls back to offering identifiers within the grant")
    func identifierFallbackStaysInsideTheGrant() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        let provider = MCPCompletionProvider(source: source)
        let prefix = String(CompletionFixtures.analyticsId.uuidString.prefix(8))

        let result = await provider.complete(
            reference: .prompt(name: "explain_schema"),
            argumentName: MCPPromptArgument.connectionArgumentName,
            argumentValue: prefix,
            context: [:],
            principal: CompletionFixtures.principal(
                connectionAccess: .limited([CompletionFixtures.analyticsId])
            )
        )

        #expect(result.values == [CompletionFixtures.analyticsId.uuidString])
    }

    @Test("An enumerated argument keeps the order the prompt declared")
    func enumeratedValuesKeepDeclaredOrder() async {
        let provider = MCPCompletionProvider(source: RecordingCompletionSource(connections: []))

        let result = await provider.complete(
            reference: .prompt(name: "explain_schema"),
            argumentName: "audience",
            argumentValue: "",
            context: [:],
            principal: CompletionFixtures.principal()
        )

        #expect(result.values == MCPPromptCatalog.audiences)
    }

    @Test("An argument with no completion source returns nothing")
    func freeTextArgumentsHaveNoCompletion() async {
        let provider = MCPCompletionProvider(source: RecordingCompletionSource(connections: []))

        let freeText = await provider.complete(
            reference: .prompt(name: "question_to_sql"),
            argumentName: "question",
            argumentValue: "how",
            context: [:],
            principal: CompletionFixtures.principal()
        )
        #expect(freeText.values.isEmpty)

        let unknown = await provider.complete(
            reference: .prompt(name: "question_to_sql"),
            argumentName: "nope",
            argumentValue: "",
            context: [:],
            principal: CompletionFixtures.principal()
        )
        #expect(unknown.values.isEmpty)
    }

    @Test("Repeated completions reuse the cache until it expires")
    func cachingAvoidsRepeatedSchemaReads() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders"])
        let clock = MCPProtocolStubClock()
        let provider = MCPCompletionProvider(source: source, clock: clock, cacheDuration: 15)

        for _ in 0 ..< 3 {
            _ = await provider.complete(
                reference: .prompt(name: "explain_table"),
                argumentName: MCPPromptArgument.tableArgumentName,
                argumentValue: "",
                context: ["connection": "Analytics"],
                principal: CompletionFixtures.principal()
            )
        }
        let firstPass = await source.tableCalls
        #expect(firstPass.count == 1)

        await clock.advance(by: .seconds(20))
        _ = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.tableArgumentName,
            argumentValue: "",
            context: ["connection": "Analytics"],
            principal: CompletionFixtures.principal()
        )
        let secondPass = await source.tableCalls
        #expect(secondPass.count == 2)
    }

    @Test("Invalidating the cache forces the next completion to read again")
    func invalidateClearsTheCache() async {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setDatabases(["warehouse"])
        let provider = MCPCompletionProvider(source: source)

        _ = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.databaseArgumentName,
            argumentValue: "",
            context: ["connection": "Analytics"],
            principal: CompletionFixtures.principal()
        )
        await provider.invalidate()
        _ = await provider.complete(
            reference: .prompt(name: "explain_table"),
            argumentName: MCPPromptArgument.databaseArgumentName,
            argumentValue: "",
            context: ["connection": "Analytics"],
            principal: CompletionFixtures.principal()
        )

        let calls = await source.databaseCalls
        #expect(calls.count == 2)
    }
}

@Suite("MCPCompletionReference")
struct MCPCompletionReferenceTests {
    @Test("A prompt reference decodes from its type and name")
    func decodesPromptReference() throws {
        let reference = try MCPCompletionReference.decode(.object([
            "type": .string(MCPCompletionReference.promptType),
            "name": .string("explain_schema")
        ]))
        #expect(reference == .prompt(name: "explain_schema"))
    }

    @Test("A resource reference decodes from its type and URI")
    func decodesResourceReference() throws {
        let reference = try MCPCompletionReference.decode(.object([
            "type": .string(MCPCompletionReference.resourceType),
            "uri": .string(ResourcesUriRoute.Template.tables)
        ]))
        #expect(reference == .resourceTemplate(uri: ResourcesUriRoute.Template.tables))
    }

    @Test("A reference with no type, no name, or no URI is invalid params")
    func rejectsIncompleteReferences() {
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPCompletionReference.decode(nil)
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPCompletionReference.decode(.object([
                "type": .string(MCPCompletionReference.promptType)
            ]))
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPCompletionReference.decode(.object([
                "type": .string(MCPCompletionReference.resourceType)
            ]))
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPCompletionReference.decode(.object(["type": .string("ref/nothing")]))
        }
    }

    @Test("Validation rejects a prompt the catalog does not hold")
    func validationRejectsUnknownPrompt() throws {
        #expect(throws: MCPProtocolError.self) {
            try MCPCompletionReference.prompt(name: "no_such_prompt").validate()
        }
        try MCPCompletionReference.prompt(name: "explain_schema").validate()
    }

    @Test("Validation rejects a URI that is neither a template nor a route")
    func validationRejectsUnknownTemplate() throws {
        #expect(throws: MCPProtocolError.self) {
            try MCPCompletionReference.resourceTemplate(uri: "https://example.com/x").validate()
        }
        try MCPCompletionReference.resourceTemplate(uri: ResourcesUriRoute.Template.table).validate()
    }

    @Test("Template variables map to the completions they can actually offer")
    func templateVariableTargets() {
        let reference = MCPCompletionReference.resourceTemplate(uri: ResourcesUriRoute.Template.tables)
        #expect(MCPCompletionTarget.resolve(reference: reference, argumentName: "connection_id") == .connectionId)
        #expect(MCPCompletionTarget.resolve(reference: reference, argumentName: "database") == .database)
        #expect(MCPCompletionTarget.resolve(reference: reference, argumentName: "schema") == .schema)
        #expect(MCPCompletionTarget.resolve(reference: reference, argumentName: "table") == .table)
        #expect(
            MCPCompletionTarget.resolve(reference: reference, argumentName: "row_counts")
                == .values(["true", "false"])
        )
        #expect(MCPCompletionTarget.resolve(reference: reference, argumentName: "unknown") == nil)
    }
}

@Suite("MCPCompletionResult")
struct MCPCompletionResultTests {
    @Test("A result serialises values, total, and hasMore")
    func jsonShape() {
        let result = MCPCompletionResult(values: ["a", "b"], total: 5)
        let json = result.asJsonValue

        #expect(json["values"]?.arrayValue?.compactMap(\.stringValue) == ["a", "b"])
        #expect(json["total"]?.intValue == 5)
        #expect(json["hasMore"]?.boolValue == true)
    }

    @Test("Duplicates and empty strings never reach the client")
    func deduplicatesCandidates() {
        let result = MCPCompletionResult.matching(["b", "a", "b", ""], prefix: "")
        #expect(result.values == ["a", "b"])
        #expect(result.total == 2)
    }

    @Test("Matching folds case on both sides")
    func matchingIsCaseInsensitive() {
        let result = MCPCompletionResult.matching(["Orders", "Customers"], prefix: "ORD")
        #expect(result.values == ["Orders"])
    }

    @Test("An empty result reports nothing and no more")
    func emptyResult() {
        #expect(MCPCompletionResult.empty.values.isEmpty)
        #expect(MCPCompletionResult.empty.total == 0)
        #expect(!MCPCompletionResult.empty.hasMore)
    }
}

@Suite("CompletionCompleteHandler")
struct CompletionCompleteHandlerTests {
    @Test("Handler declares completion/complete and the resources read scope")
    func metadata() {
        #expect(CompletionCompleteHandler.method == "completion/complete")
        #expect(CompletionCompleteHandler.requiredScopes == [.resourcesRead])
    }

    @Test("A completion answers under the completion key with values, total, and hasMore")
    func returnsCompletionPayload() async throws {
        let result = try await complete(params: .object([
            "ref": .object([
                "type": .string(MCPCompletionReference.promptType),
                "name": .string("explain_schema")
            ]),
            "argument": .object(["name": .string("audience"), "value": .string("")])
        ]))

        let completion = try #require(result.payload["completion"])
        #expect(completion["values"]?.arrayValue?.compactMap(\.stringValue) == MCPPromptCatalog.audiences)
        #expect(completion["total"]?.intValue == MCPPromptCatalog.audiences.count)
        #expect(completion["hasMore"]?.boolValue == false)
    }

    @Test("A completion result is never cacheable")
    func completionIsNotCacheable() async throws {
        let result = try await complete(params: .object([
            "ref": .object([
                "type": .string(MCPCompletionReference.promptType),
                "name": .string("explain_schema")
            ]),
            "argument": .object(["name": .string("audience"), "value": .string("")])
        ]))
        #expect(result.cacheHint == nil)
    }

    @Test("A reference to a prompt that does not exist is invalid params")
    func unknownPromptReference() async throws {
        let error = try await failure(params: .object([
            "ref": .object([
                "type": .string(MCPCompletionReference.promptType),
                "name": .string("no_such_prompt")
            ]),
            "argument": .object(["name": .string("audience"), "value": .string("")])
        ]))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A missing argument object, name, or value is invalid params")
    func missingArgumentFields() async throws {
        let reference = JsonValue.object([
            "type": .string(MCPCompletionReference.promptType),
            "name": .string("explain_schema")
        ])

        let noArgument = try await failure(params: .object(["ref": reference]))
        #expect(noArgument.code == JsonRpcErrorCode.invalidParams)

        let noName = try await failure(params: .object([
            "ref": reference,
            "argument": .object(["value": .string("")])
        ]))
        #expect(noName.code == JsonRpcErrorCode.invalidParams)

        let noValue = try await failure(params: .object([
            "ref": reference,
            "argument": .object(["name": .string("audience")])
        ]))
        #expect(noValue.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("Already-resolved arguments reach the provider as completion context")
    func resolvedArgumentsBecomeContext() async throws {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        await source.setTables(["orders"])
        let handler = CompletionCompleteHandler(provider: MCPCompletionProvider(source: source))
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: CompletionCompleteHandler.method,
            principalScopes: MCPScope.readOnlySet
        )

        _ = try await handler.handle(
            params: .object([
                "ref": .object([
                    "type": .string(MCPCompletionReference.promptType),
                    "name": .string("explain_table")
                ]),
                "argument": .object(["name": .string("table"), "value": .string("")]),
                "context": .object([
                    "arguments": .object([
                        "connection": .string("Analytics"),
                        "database": .string("warehouse")
                    ])
                ])
            ]),
            context: context
        )

        let call = try #require(await source.tableCalls.first)
        #expect(call.connectionId == CompletionFixtures.analyticsId)
        #expect(call.database == "warehouse")
    }

    private func complete(params: JsonValue?) async throws -> MCPResult {
        let source = RecordingCompletionSource(connections: CompletionFixtures.connections)
        let handler = CompletionCompleteHandler(provider: MCPCompletionProvider(source: source))
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: CompletionCompleteHandler.method,
            params: params,
            principalScopes: MCPScope.readOnlySet
        )
        return try await handler.handle(params: params, context: context)
    }

    private func failure(params: JsonValue?) async throws -> MCPProtocolError {
        do {
            let result = try await complete(params: params)
            Issue.record("Expected an MCPProtocolError, got \(result)")
            throw CompletionTestError.unexpectedSuccess
        } catch let error as MCPProtocolError {
            return error
        }
    }
}

enum CompletionTestError: Error {
    case unexpectedSuccess
}

enum CompletionFixtures {
    static let analyticsId = UUID(uuidString: "0A000000-0000-4000-8000-000000000001") ?? UUID()
    static let billingId = UUID(uuidString: "0B000000-0000-4000-8000-000000000002") ?? UUID()
    static let thirdId = UUID(uuidString: "0C000000-0000-4000-8000-000000000003") ?? UUID()

    static let connections: [MCPConnectionDescriptor] = [
        MCPConnectionDescriptor(
            id: analyticsId,
            name: "Analytics",
            databaseType: "PostgreSQL",
            database: "warehouse",
            isConnected: true,
            safeMode: "off"
        ),
        MCPConnectionDescriptor(
            id: billingId,
            name: "Billing",
            databaseType: "MySQL",
            database: "shop",
            isConnected: true,
            safeMode: "restricted"
        )
    ]

    static func principal(connectionAccess: ConnectionAccess = .all) -> MCPPrincipal {
        MCPProtocolTestSupport.makePrincipal(
            scopes: MCPScope.readOnlySet,
            connectionAccess: connectionAccess
        )
    }
}

actor RecordingCompletionSource: MCPCompletionSchemaSource {
    struct DatabaseCall: Sendable, Equatable {
        let connectionId: UUID
    }

    struct SchemaCall: Sendable, Equatable {
        let connectionId: UUID
        let database: String?
    }

    struct TableCall: Sendable, Equatable {
        let connectionId: UUID
        let database: String?
        let schema: String?
    }

    private let storedConnections: [MCPConnectionDescriptor]
    private var storedDatabases: [String] = []
    private var storedSchemas: [String] = []
    private var storedTables: [String] = []

    private(set) var databaseCalls: [DatabaseCall] = []
    private(set) var schemaCalls: [SchemaCall] = []
    private(set) var tableCalls: [TableCall] = []

    init(connections: [MCPConnectionDescriptor]) {
        storedConnections = connections
    }

    func setDatabases(_ databases: [String]) {
        storedDatabases = databases
    }

    func setSchemas(_ schemas: [String]) {
        storedSchemas = schemas
    }

    func setTables(_ tables: [String]) {
        storedTables = tables
    }

    func connections(principal: MCPPrincipal) async -> [MCPConnectionDescriptor] {
        storedConnections.filter { principal.connectionAccess.allows($0.id) }
    }

    func databases(connectionId: UUID) async -> [String] {
        databaseCalls.append(DatabaseCall(connectionId: connectionId))
        return storedDatabases
    }

    func schemas(connectionId: UUID, database: String?) async -> [String] {
        schemaCalls.append(SchemaCall(connectionId: connectionId, database: database))
        return storedSchemas
    }

    func tables(connectionId: UUID, database: String?, schema: String?) async -> [String] {
        tableCalls.append(TableCall(connectionId: connectionId, database: database, schema: schema))
        return storedTables
    }
}
