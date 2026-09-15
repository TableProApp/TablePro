import Foundation
@testable import TableProWeaviateCore
import Testing

@Suite("Weaviate client")
struct WeaviateClientTests {
    @Test("Connect reads ready and meta, and stores the version")
    func connectStoresVersion() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "GET", path: "/v1/.well-known/ready", status: 200, body: ".")
        transport.respond(method: "GET", path: "/v1/meta", status: 200, json: WeaviateFixtures.meta)
        let client = testClient(transport: transport)

        try await client.connect()

        #expect(client.serverVersion == "1.27.0")
        #expect(transport.requests.map { $0.url.path } == ["/v1/.well-known/ready", "/v1/meta"])
    }

    @Test("An API key is sent as a Bearer header")
    func apiKeyIsBearer() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "GET", path: "/v1/meta", status: 200, json: WeaviateFixtures.meta)
        let client = testClient(
            transport: transport,
            auth: WeaviateAuth(method: .apiKey, apiKey: "wv-secret")
        )

        try await client.ping()

        #expect(transport.requests.first?.headers["Authorization"] == "Bearer wv-secret")
    }

    @Test("A ping asks an endpoint that checks the key")
    func pingIsAuthenticated() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "GET", path: "/v1/meta", status: 200, json: WeaviateFixtures.meta)
        let client = testClient(transport: transport)

        try await client.ping()

        #expect(transport.requests.map { $0.url.path } == ["/v1/meta"])
    }

    @Test("Anonymous auth sends no Authorization header")
    func anonymousHasNoAuthorization() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "GET", path: "/v1/meta", status: 200, json: WeaviateFixtures.meta)
        let client = testClient(transport: transport)

        try await client.ping()

        #expect(transport.requests.first?.headers["Authorization"] == nil)
    }

    @Test("Schema lists collections and properties")
    func schemaListsCollections() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "GET", path: "/v1/schema", status: 200, json: WeaviateFixtures.schema)
        let client = testClient(transport: transport)

        let collections = try await client.schema()

        #expect(collections.map(\.name) == ["Article"])
        #expect(collections.first?.properties.map(\.name) == ["title", "wordCount"])
        #expect(collections.first?.properties.map(\.dataType) == ["text", "int"])
    }

    @Test("Objects include uuid, properties and the vector as display text")
    func objectsIncludeUUIDAndVector() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "GET", path: "/v1/objects", status: 200, json: WeaviateFixtures.objects)
        let client = testClient(transport: transport)

        let objects = try await client.objects(collection: "Article", limit: 25, offset: 0)
        let object = try #require(objects.first)
        let columns = ["uuid", "title", "wordCount", "vector"]
        let row = WeaviateObjectCodec.row(for: object, columns: columns)

        #expect(object.uuid == WeaviateFixtures.articleUUID)
        #expect(row[0] == WeaviateFixtures.articleUUID)
        #expect(row[1] == "Hello")
        #expect(row[2] == "12")
        #expect(row[3]?.contains("0.1") == true)
        #expect(row[3]?.hasPrefix("[") == true)
        #expect(transport.requests.first?.url.query?.contains("class=Article") == true)
        #expect(transport.requests.first?.url.query?.contains("include=vector") == true)
    }

    @Test("HTTP 401 becomes an authentication error")
    func unauthorizedIsAuthentication() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(
            method: "GET",
            path: "/v1/meta",
            status: 401,
            json: ["error": [["message": "invalid api key"]]]
        )
        let client = testClient(transport: transport)

        await #expect(throws: WeaviateError.authentication("invalid api key")) {
            try await client.ping()
        }
    }

    @Test("A server error body is surfaced")
    func serverErrorMessage() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(
            method: "GET",
            path: "/v1/schema",
            status: 500,
            json: ["error": [["message": "store unavailable"]]]
        )
        let client = testClient(transport: transport)

        await #expect(throws: WeaviateError.api(status: 500, message: "store unavailable")) {
            _ = try await client.schema()
        }
    }

    @Test("GraphQL Get rows flatten uuid from _additional")
    func graphqlGetFlattensUUID() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(method: "POST", path: "/v1/graphql", status: 200, json: WeaviateFixtures.graphqlGet)
        let client = testClient(transport: transport)

        let response = try await client.graphql("{ Get { Article { title } } }")
        let objects = WeaviateObjectCodec.objects(fromGraphQL: response.json as Any)
        let object = try #require(objects.first)

        #expect(object.uuid == WeaviateFixtures.articleUUID)
        #expect(object.properties["title"] == "Hello")
        #expect(object.vectorText?.contains("0.1") == true)
    }

    @Test("GraphQL errors in a 200 response still fail")
    func graphqlErrorsFail() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(
            method: "POST",
            path: "/v1/graphql",
            status: 200,
            json: ["errors": [["message": "Cannot query field"]]]
        )
        let client = testClient(transport: transport)

        await #expect(throws: WeaviateError.api(status: 200, message: "Cannot query field")) {
            _ = try await client.graphql("{ Get { Missing { title } } }")
        }
    }
}

@Suite("Weaviate uuid edits")
struct WeaviateUUIDEditTests {
    @Test("An update is a PATCH keyed by uuid and does not write uuid or vector")
    func updateIsPatchByUUID() async throws {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "title", "vector"],
            typeNames: ["uuid", "text", "vector"],
            changes: [
                WeaviateTrackedChange(
                    kind: .update,
                    uuid: WeaviateFixtures.articleUUID,
                    values: [:],
                    cellChanges: [
                        WeaviateCellChange(column: "title", newText: "Edited"),
                        WeaviateCellChange(column: "vector", newText: "[9,9]"),
                        WeaviateCellChange(column: "uuid", newText: "nope")
                    ]
                )
            ]
        )
        let request = try #require(batch.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/v1/objects/\(WeaviateFixtures.articleUUID)")
        #expect(request.query["class"] == "Article")
        let body = try #require(request.body)
        #expect(body.contains("\"title\":\"Edited\""))
        #expect(!body.contains("vector"))
        #expect(!body.contains("nope"))

        let transport = FakeWeaviateTransport()
        transport.respond(
            method: "PATCH",
            path: "/v1/objects/\(WeaviateFixtures.articleUUID)",
            status: 200,
            json: ["id": WeaviateFixtures.articleUUID]
        )
        let client = testClient(transport: transport)
        let response = try await client.execute(write: request)
        #expect(response.statusCode == 200)
        #expect(transport.requests.first?.httpMethodMatchesPatch == true)
    }

    @Test("A delete is DELETE /v1/objects/{uuid}")
    func deleteUsesUUID() async throws {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "title"],
            typeNames: ["uuid", "text"],
            changes: [
                WeaviateTrackedChange(
                    kind: .delete,
                    uuid: WeaviateFixtures.articleUUID,
                    values: [:],
                    cellChanges: []
                )
            ]
        )
        let request = try #require(batch.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path.hasSuffix(WeaviateFixtures.articleUUID))

        let transport = FakeWeaviateTransport()
        transport.respond(
            method: "DELETE",
            path: "/v1/objects/\(WeaviateFixtures.articleUUID)",
            status: 204,
            body: ""
        )
        let client = testClient(transport: transport)
        let response = try await client.execute(write: request)
        #expect(response.statusCode == 204)
    }

    @Test("An update without a uuid is skipped")
    func updateWithoutUUIDIsSkipped() {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "title"],
            typeNames: ["uuid", "text"],
            changes: [
                WeaviateTrackedChange(
                    kind: .update,
                    uuid: nil,
                    values: [:],
                    cellChanges: [WeaviateCellChange(column: "title", newText: "Edited")]
                )
            ]
        )
        #expect(batch.requests.isEmpty)
        #expect(batch.skipped == [WeaviateSkippedChange(kind: .update, reason: .missingUUID)])
    }

    @Test("Insert posts the collection and properties, and an explicit uuid")
    func insertPostsObject() throws {
        let batch = WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["uuid", "title", "wordCount"],
            typeNames: ["uuid", "text", "int"],
            changes: [
                WeaviateTrackedChange(
                    kind: .insert,
                    uuid: WeaviateFixtures.articleUUID,
                    values: [
                        "uuid": WeaviateFixtures.articleUUID,
                        "title": "Hello",
                        "wordCount": "12"
                    ],
                    cellChanges: []
                )
            ]
        )
        let request = try #require(batch.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/objects")
        let body = try #require(request.body)
        #expect(body.contains("\"class\":\"Article\""))
        #expect(body.contains("\"id\":\"\(WeaviateFixtures.articleUUID)\""))
        #expect(body.contains("\"title\":\"Hello\""))
        #expect(body.contains("\"wordCount\":12"))
    }
}

private extension WeaviateHTTPRequest {
    var httpMethodMatchesPatch: Bool { method == "PATCH" }
}
