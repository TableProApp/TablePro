//
//  SchemaRegistryTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import Testing

// Recorded from confluentinc/cp-schema-registry 7.7.1. The values were written by confluent-kafka 2.6.1's
// AvroSerializer and ProtobufSerializer against it, and the expected texts are what those libraries decode.
struct SchemaRegistryTests {
    private static let responses: [String: (Int, String)] = [
        "/schemas/ids/1": (200, #"{"schema":"{\"type\":\"record\",\"name\":\"User\",\"namespace\":\"com.example\",\"fields\":[{\"name\":\"id\",\"type\":\"long\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"email\",\"type\":[\"null\",\"string\"]},{\"name\":\"kind\",\"type\":{\"type\":\"enum\",\"name\":\"Kind\",\"symbols\":[\"A\",\"B\"]}}]}"}"#),
        "/schemas/ids/3": (200, #"{"schemaType":"PROTOBUF","schema":"syntax = \"proto3\";\npackage demo;\n\nimport \"demo/common.proto\";\n\nmessage Order {\n  string id = 1;\n  .demo.Money total = 2;\n  repeated string tags = 3;\n  .demo.Status status = 4;\n  repeated .demo.Order.Line lines = 5;\n  repeated .demo.Order.CountsEntry counts = 6;\n\n  message Line {\n    string sku = 1;\n    sint32 qty = 2;\n  }\n  message CountsEntry {\n    option map_entry = true;\n  \n    string key = 1;\n    int32 value = 2;\n  }\n}\nmessage Refund {\n  string order_id = 1;\n  double amount = 2;\n}\nenum Status {\n  STATUS_UNKNOWN = 0;\n  STATUS_PAID = 1;\n}\n","references":[{"name":"demo/common.proto","subject":"demo/common.proto","version":1}]}"#),
        "/subjects/demo%2Fcommon.proto/versions/1": (200, #"{"subject":"demo/common.proto","version":1,"id":2,"schemaType":"PROTOBUF","schema":"syntax = \"proto3\";\npackage demo;\n\nmessage Money {\n  string currency = 1;\n  int64 units = 2;\n}\n"}"#),
        "/schemas/ids/99999": (404, #"{"error_code":40403,"message":"Schema 99999 not found"}"#),
    ]

    private static let avroUser = "00000000015406416e6e021e616e6e406578616d706c652e636f6d02"
    private static let order = "0000000003000a036f2d3112080a0345555210e2091a01611a016220012a050a0178100532050a016b1007"
    private static let refund = "000000000302020a036f2d31110000000000002940"

    private static let endpoint = SchemaRegistryEndpoint(fields: [
        SchemaRegistryConnectionField.url: "https://registry.example.com/base/",
        SchemaRegistryConnectionField.username: "key",
        SchemaRegistryConnectionField.password: "secret",
    ])

    private final class RecordedTransport: Sendable {
        let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

        var transport: SchemaRegistryClient.Transport {
            { [self] request in
                requests.withLock { $0.append(request) }
                let path = String((request.url?.absoluteString ?? "").dropFirst("https://registry.example.com/base".count))
                let (status, body) = SchemaRegistryTests.responses[path] ?? (404, #"{"message":"no such path"}"#)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }
    }

    private func fetch(_ id: UInt32, transport: RecordedTransport = RecordedTransport()) async throws -> RegistrySchema {
        try await SchemaRegistryClient(endpoint: try #require(Self.endpoint), transport: transport.transport).schema(id: id)
    }

    @Test("An Avro value decodes with the schema its prefix names")
    func avro() async throws {
        let schema = try await fetch(1)
        let text = try BinaryValueDecoding.registryText(BinaryFixture.data(Self.avroUser), schema: schema, maxValues: .max, limit: .max)
        #expect(text == #"{"id":42,"name":"Ann","email":"ann@example.com","kind":"B"}"#)
        guard case .decoded(.json, _, let note) = try BinaryValueDecoding.registryDocument(BinaryFixture.data(Self.avroUser), schema: schema) else {
            Issue.record("expected a decoded JSON tree")
            return
        }
        #expect(note?.contains("1") == true)
    }

    @Test("A Protobuf schema is fetched with the files it imports, and the message index picks the message")
    func protobuf() async throws {
        let transport = RecordedTransport()
        let schema = try await fetch(3, transport: transport)
        let paths = transport.requests.withLock { $0.compactMap { $0.url?.path(percentEncoded: true) } }
        #expect(paths == ["/base/schemas/ids/3", "/base/subjects/demo%2Fcommon.proto/versions/1"])

        let order = try BinaryValueDecoding.registryText(BinaryFixture.data(Self.order), schema: schema, maxValues: .max, limit: .max)
        #expect(order == #"id: "o-1" total { currency: "EUR" units: 1250 } tags: "a" tags: "b" status: STATUS_PAID "#
            + #"lines { sku: "x" qty: -3 } counts { key: "k" value: 7 }"#)

        guard case .decoded(.protobuf, let text, let note) = try BinaryValueDecoding.registryDocument(
            BinaryFixture.data(Self.refund), schema: schema
        ) else {
            Issue.record("expected a decoded Protobuf tree")
            return
        }
        #expect(text == "order_id: \"o-1\"\namount: 12.5\n")
        #expect(note?.contains("3") == true)
    }

    @Test("An Avro schema can name a type another subject defines")
    func avroReferences() throws {
        let money = #"{"type":"record","name":"Money","namespace":"demo","fields":[{"name":"units","type":"long"}]}"#
        let order = #"{"type":"record","name":"Order","namespace":"demo","fields":[{"name":"total","type":"demo.Money"}]}"#
        #expect(throws: AvroSchemaError.self) { try AvroSchema.parse(order) }
        let schema = try AvroSchema.parse(order, references: [money])
        let text = try BinaryValueDecoding.registryText(BinaryFixture.data("000000000754"), schema: .avro(schema), maxValues: .max, limit: .max)
        #expect(text == #"{"total":{"units":42}}"#)
    }

    @Test("Every request carries the connection's credentials")
    func basicAuth() async throws {
        let transport = RecordedTransport()
        _ = try await fetch(1, transport: transport)
        let header = transport.requests.withLock { $0.first?.value(forHTTPHeaderField: "Authorization") }
        #expect(header == "Basic " + Data("key:secret".utf8).base64EncodedString())
    }

    @Test("The registry's own error message is the reason a schema is missing")
    func notFound() async {
        await #expect(throws: SchemaRegistryError(reason: "The Schema Registry answered 404: Schema 99999 not found")) {
            try await fetch(99_999)
        }
    }

    @Test("Only an http or https URL names a registry")
    func endpointSchemes() {
        #expect(SchemaRegistryEndpoint(fields: [SchemaRegistryConnectionField.url: "file:///etc/passwd"]) == nil)
        #expect(SchemaRegistryEndpoint(fields: [SchemaRegistryConnectionField.url: ""]) == nil)
        #expect(SchemaRegistryEndpoint(fields: [:]) == nil)
        #expect(SchemaRegistryEndpoint(fields: [SchemaRegistryConnectionField.url: " http://localhost:8081 "])?.username == nil)
    }

    @Test("A value without the prefix, or one its schema cannot read, is refused, so the cell stays hex")
    func brokenValues() async throws {
        let avro = try await fetch(1)
        #expect(throws: BinaryValueDecodeError(kind: .notFramed, offset: 0)) {
            try SchemaRegistryFrame.schemaID(BinaryFixture.data("5406416e6e"))
        }
        #expect(throws: BinaryValueDecodeError.self) {
            try BinaryValueDecoding.registryText(BinaryFixture.data("000000000154"), schema: avro, maxValues: .max, limit: .max)
        }
        let protobuf = try await fetch(3)
        #expect(throws: BinaryValueDecodeError.self) {
            try BinaryValueDecoding.registryText(BinaryFixture.data("000000000302080a"), schema: protobuf, maxValues: .max, limit: .max)
        }
    }

    @Test("The cache asks once for many cells, tells the grid when the schema lands, and keeps a failure only briefly")
    func cache() async throws {
        let transport = RecordedTransport()
        let connection = UUID()
        let cache = SchemaRegistryCache(endpoint: { _ in Self.endpoint }, transport: transport.transport)
        let (landed, continuation) = AsyncStream<UUID>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: SchemaRegistryCache.didLoadSchema, object: cache, queue: nil) {
            if let id = $0.userInfo?[SchemaRegistryCache.connectionIDKey] as? UUID { continuation.yield(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(cache.cachedSchema(connectionID: connection, schemaID: 1) == nil)
        #expect(cache.cachedSchema(connectionID: connection, schemaID: 1) == nil)
        var iterator = landed.makeAsyncIterator()
        #expect(await iterator.next() == connection)
        guard case .success(.avro)? = cache.cachedSchema(connectionID: connection, schemaID: 1) else {
            Issue.record("expected the fetched Avro schema")
            return
        }
        #expect(transport.requests.withLock { $0.count } == 1)

        guard case .failure = await cache.schema(connectionID: connection, schemaID: 99_999) else {
            Issue.record("expected a failure")
            return
        }
        guard case .failure? = cache.cachedSchema(connectionID: connection, schemaID: 99_999) else {
            Issue.record("expected the failure to be kept")
            return
        }
        #expect(transport.requests.withLock { $0.count } == 2)
    }

    @Test("A connection with no registry URL says so instead of fetching")
    func noEndpoint() async {
        let cache = SchemaRegistryCache(endpoint: { _ in nil }, transport: { _ in throw URLError(.badURL) })
        guard case .failure(let error) = await cache.schema(connectionID: UUID(), schemaID: 1) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.reason.contains("Schema Registry URL"))
    }
}
