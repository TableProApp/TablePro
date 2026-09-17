import Foundation
@testable import TableProWeaviateCore
import Testing

@Suite("Weaviate auth and settings")
struct WeaviateAuthTests {
    @Test("Field ids stay Weaviate-prefixed")
    func fieldIdsArePrefixed() {
        #expect(WeaviateFieldID.authMethod == "wvAuthMethod")
        #expect(WeaviateFieldID.apiKey == "wvApiKey")
        #expect(WeaviateFieldID.skipTLSVerify == "wvSkipTLSVerify")
        #expect(WeaviateFieldID.authMethod != "esAuthMethod")
        #expect(WeaviateFieldID.apiKey != "esApiKey")
    }

    @Test("API key mode without a key is refused")
    func apiKeyRequiresValue() {
        #expect(throws: WeaviateError.configuration("Enter a Weaviate API key.")) {
            _ = try WeaviateConnectionSettings.parse(
                host: "localhost",
                port: 8_080,
                usesTLS: false,
                fields: [WeaviateFieldID.authMethod: "apiKey"]
            )
        }
    }

    @Test("A pasted key is not sent when Auth Method is None")
    func noneModeIgnoresAPastedKey() throws {
        let settings = try WeaviateConnectionSettings.parse(
            host: "localhost",
            port: 8_080,
            usesTLS: false,
            fields: [
                WeaviateFieldID.authMethod: "none",
                WeaviateFieldID.apiKey: "wv-secret"
            ]
        )
        #expect(settings.auth.authorizationHeader == nil)
    }

    @Test("None mode does not require a key")
    func noneModeConnects() throws {
        let settings = try WeaviateConnectionSettings.parse(
            host: "localhost",
            port: 0,
            usesTLS: false,
            fields: [WeaviateFieldID.authMethod: "none"]
        )
        #expect(settings.port == 8_080)
        #expect(settings.auth.authorizationHeader == nil)
        #expect(try settings.baseURL().absoluteString == "http://localhost:8080")
    }

    @Test("TLS uses https")
    func tlsUsesHTTPS() throws {
        let settings = try WeaviateConnectionSettings.parse(
            host: "example.weaviate.cloud",
            port: 443,
            usesTLS: true,
            fields: [
                WeaviateFieldID.authMethod: "apiKey",
                WeaviateFieldID.apiKey: "key"
            ]
        )
        #expect(try settings.baseURL().absoluteString == "https://example.weaviate.cloud:443")
        #expect(settings.auth.authorizationHeader == "Bearer key")
    }
}

@Suite("Weaviate query tags")
struct WeaviateQueryTests {
    @Test("Browse tags round-trip")
    func browseRoundTrip() throws {
        let encoded = WeaviateBrowseQuery.encode(
            collection: "Article",
            offset: 10,
            limit: 25,
            sorts: [WeaviateSortSpec(column: "title", ascending: true)],
            filters: [WeaviateFilterSpec(column: "title", op: "=", value: "Hello")],
            logicMode: "AND",
            propertyNames: ["uuid", "title"]
        )
        #expect(WeaviateBrowseQuery.isTagged(encoded))
        let parsed = try #require(WeaviateBrowseQuery.parse(encoded))
        #expect(parsed.collection == "Article")
        #expect(parsed.offset == 10)
        #expect(parsed.limit == 25)
        #expect(parsed.usesGraphQL)
        #expect(parsed.filters.first?.value == "Hello")
    }

    @Test("An unfiltered browse stays on REST objects")
    func unfilteredUsesREST() throws {
        let encoded = WeaviateBrowseQuery.encode(
            collection: "Article",
            offset: 0,
            limit: 25,
            sorts: [],
            filters: [],
            logicMode: "AND",
            propertyNames: ["uuid", "title"]
        )
        let parsed = try #require(WeaviateBrowseQuery.parse(encoded))
        #expect(!parsed.usesGraphQL)
    }

    @Test("Write tags round-trip")
    func writeRoundTrip() throws {
        let original = WeaviateWriteRequest(
            method: "PATCH",
            path: "/v1/objects/abc",
            query: ["class": "Article"],
            body: "{\"title\":\"x\"}"
        )
        let encoded = WeaviateWriteCodec.encode(original)
        #expect(WeaviateWriteCodec.isTagged(encoded))
        #expect(WeaviateWriteCodec.decode(encoded) == original)
    }
}

@Suite("Weaviate GraphQL and console")
struct WeaviateGraphQLTests {
    @Test("A Get query asks for _additional id and vector")
    func getQueryIncludesAdditional() throws {
        let query = try WeaviateGraphQL.getQuery(
            collection: "Article",
            properties: ["uuid", "title", "vector"],
            limit: 10,
            offset: 0,
            sorts: [],
            filters: [WeaviateFilterSpec(column: "title", op: "=", value: "Hello")],
            logicMode: "AND",
            schema: ["title": WeaviateProperty(name: "title", dataType: "text")]
        )
        #expect(query.contains("Get"))
        #expect(query.contains("Article"))
        #expect(query.contains("title"))
        #expect(query.contains("_additional { id vector }"))
        #expect(query.contains("operator: Equal"))
        #expect(query.contains("valueText: \"Hello\""))
        #expect(!query.contains(" uuid "))
    }

    @Test("GraphQL detection")
    func detection() {
        #expect(WeaviateGraphQL.looksLikeGraphQL("{ Get { Article { title } } }"))
        #expect(WeaviateGraphQL.looksLikeGraphQL("query { Get { Article { title } } }"))
        #expect(!WeaviateGraphQL.looksLikeGraphQL("GET /v1/schema"))
    }

    @Test("Console parser reads a method and path")
    func consoleParser() throws {
        let request = try #require(WeaviateConsoleParser.parse("GET /v1/schema"))
        #expect(request.method == "GET")
        #expect(request.path == "/v1/schema")
        #expect(request.body == nil)

        let withBody = try #require(WeaviateConsoleParser.parse("POST /v1/graphql\n{ \"query\": \"{ Get { Article { title } } }\" }"))
        #expect(withBody.method == "POST")
        #expect(withBody.body?.contains("Get") == true)
    }

    @Test("A SQL delete is not a console request")
    func sqlIsNotConsole() {
        #expect(WeaviateConsoleParser.parse("DELETE FROM Article") == nil)
        #expect(WeaviateConsoleParser.parse("UPDATE Article SET title = 'x'") == nil)
        #expect(WeaviateConsoleParser.parse("GET schema") == nil)
    }
}

@Suite("Weaviate columns")
struct WeaviateSchemaTests {
    @Test("uuid leads and vector trails, and both are the primary key surface")
    func columnOrder() {
        let collection = WeaviateCollection(
            name: "Article",
            properties: [WeaviateProperty(name: "title", dataType: "text")]
        )
        let columns = WeaviateSchema.columns(for: collection)
        #expect(columns.map(\.name) == ["uuid", "title", "vector"])
        #expect(columns.first?.isPrimaryKey == true)
        #expect(WeaviateSchema.immutableColumns == ["uuid", "vector"])
    }

    @Test("Object and array properties display as JSON")
    func displayTextEncodesCollections() {
        #expect(WeaviateJSON.displayText(["title": "Hello"]) == "{\"title\":\"Hello\"}")
        let vector = WeaviateJSON.displayText([0.1, 0.2])
        #expect(vector?.hasPrefix("[") == true)
        #expect(vector?.hasSuffix("]") == true)
        #expect(WeaviateJSON.displayText(true) == "true")
        #expect(WeaviateJSON.displayText(NSNull()) == nil)
    }
}
