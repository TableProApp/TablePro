//
//  ConnectionEditorEngineHostListTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineHostListTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func loaded(_ connection: DatabaseConnection) -> ConnectionDraft {
        ConnectionDraft.loaded(from: connection, secrets: .none, traits: traits(connection.type))
    }

    private func draft(type: DatabaseType, fields: [String: String]) -> ConnectionDraft {
        var draft = ConnectionDraft.new(type: type, traits: traits(type))
        draft.name = "cluster"
        for (id, value) in fields {
            draft.setFieldValue(value, for: id)
        }
        return draft
    }

    private func edits(_ draft: ConnectionDraft) -> ConnectionFormEdits {
        ConnectionEditorEngine.edits(draft, traits(draft.type), originalTraits: nil, EditorContext())
    }

    private func issues(_ draft: ConnectionDraft) -> [FieldIssue] {
        ConnectionEditorEngine.issues(draft, traits(draft.type), EditorContext())
    }

    @Test("An Elasticsearch connection saved with Host and Port opens with them as its node list")
    func elasticsearchSeedsFromHostAndPort() {
        let draft = loaded(DatabaseConnection(name: "es", host: "es1.example", port: 9_201, type: .elasticsearch))
        #expect(draft.fieldValues["esHosts"] == "es1.example:9201")
    }

    @Test("A Kafka connection opens with the broker it dials, not a blank list")
    func kafkaSeedsFromHostAndPort() {
        let draft = loaded(DatabaseConnection(name: "k", host: "broker1.example", port: 9_092, type: .kafka))
        #expect(draft.fieldValues["kafkaBootstrapServers"] == "broker1.example:9092")
    }

    @Test("A Kafka list saved as extra brokers shows the hidden Host as its last row")
    func kafkaLegacyListKeepsHost() {
        let draft = loaded(DatabaseConnection(
            name: "k",
            host: "broker1.example",
            port: 9_092,
            type: .kafka,
            additionalFields: ["kafkaBootstrapServers": "b2.example:9092"]
        ))
        #expect(draft.fieldValues["kafkaBootstrapServers"] == "b2.example:9092,broker1.example:9092")
    }

    @Test("A Host the form filled in while it was hidden is not added to a saved list")
    func defaultHostStaysOut() {
        let draft = loaded(DatabaseConnection(
            name: "es",
            host: "localhost",
            port: 9_200,
            type: .elasticsearch,
            additionalFields: ["esHosts": "es1.example:9200,es2.example:9200"]
        ))
        #expect(draft.fieldValues["esHosts"] == "es1.example:9200,es2.example:9200")
    }

    @Test("A legacy Kafka broker on localhost with its own port stays in the list")
    func legacyLocalhostOnOtherPortStays() {
        let draft = loaded(DatabaseConnection(
            name: "k",
            host: "localhost",
            port: 9_093,
            type: .kafka,
            additionalFields: ["kafkaBootstrapServers": "broker2.example:9092"]
        ))
        #expect(draft.fieldValues["kafkaBootstrapServers"] == "broker2.example:9092,localhost:9093")
    }

    @Test("Clearing every row connects to the placeholder, not the Host the list hid")
    func clearedListUsesDefaults() {
        var cleared = draft(type: .elasticsearch, fields: ["esHosts": " , "])
        cleared.host = "old.example"
        cleared.portText = "9300"
        let result = edits(cleared)
        #expect(result.host == "localhost")
        #expect(result.port == 9_200)
        #expect(result.additionalFields["esHosts"] == "")
    }

    @Test("Redis lists belong to one mode and are never seeded from Host")
    func redisListsAreNotSeeded() {
        let draft = loaded(DatabaseConnection(name: "r", host: "cache.example", port: 6_379, type: .redis))
        #expect((draft.fieldValues["redisClusterHosts"] ?? "").isEmpty)
        #expect((draft.fieldValues["redisSentinelHosts"] ?? "").isEmpty)
    }

    @Test("Saving pasted node URLs stores host:port entries and takes Host and Port from the first")
    func elasticsearchSaveNormalizesNodes() {
        let result = edits(draft(
            type: .elasticsearch,
            fields: ["esHosts": "https://111.111.111.111:9200,https://111.111.111.112:9200,https://[fd00::3]:9200"]
        ))
        #expect(result.additionalFields["esHosts"] == "111.111.111.111:9200,111.111.111.112:9200,[fd00::3]:9200")
        #expect(result.host == "111.111.111.111")
        #expect(result.port == 9_200)
    }

    @Test("A blank row is dropped, not saved as localhost")
    func blankRowIsDropped() {
        let result = edits(draft(type: .mongodb, fields: ["mongoHosts": ",a.example:27017, ,b.example"]))
        #expect(result.additionalFields["mongoHosts"] == "a.example:27017,b.example:27017")
        #expect(result.host == "a.example")
        #expect(result.port == 27_017)
    }

    @Test("A row that is not a host blocks Save instead of being dropped")
    func invalidRowIsAnIssue() {
        let rowIssues = issues(draft(type: .elasticsearch, fields: ["esHosts": "es1:9200,es2:abc"]))
            .filter { $0.row == .plugin(fieldID: "esHosts") }
        #expect(rowIssues.count == 1)
        #expect(rowIssues.first?.message.contains("es2:abc") == true)
    }

    @Test("An https:// node needs SSL turned on, or its credentials would go over plain HTTP")
    func httpsNodeNeedsSSL() {
        var secure = draft(type: .elasticsearch, fields: ["esHosts": "https://10.0.0.1:9200"])
        secure.selectSSLMode(.disabled)
        #expect(issues(secure).contains { $0.message.contains("https://10.0.0.1:9200") })

        secure.selectSSLMode(.required)
        #expect(!issues(secure).contains { $0.message.contains("https://10.0.0.1:9200") })
        #expect(!issues(secure).contains { $0.row == .plugin(fieldID: "esHosts") })
    }

    @Test("Switching another type's Host to Elasticsearch carries it into the node list")
    func typeChangeSeedsTheList() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.host = "db.example"
        draft.retype(to: traits(.elasticsearch), from: mysql)
        #expect(draft.fieldValues["esHosts"] == "db.example:9200")
    }

    @Test("Kafka Host and Port follow the first bootstrap server")
    func kafkaHostFollowsFirstServer() {
        let result = edits(draft(type: .kafka, fields: ["kafkaBootstrapServers": "b1.example:9093,b2.example:9092"]))
        #expect(result.host == "b1.example")
        #expect(result.port == 9_093)
    }
}
