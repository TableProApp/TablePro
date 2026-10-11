//
//  EndpointHostListFormTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct EndpointHostListFormTests {
    private func loaded(_ connection: DatabaseConnection) -> NetworkPaneViewModel {
        let viewModel = NetworkPaneViewModel()
        viewModel.load(from: connection)
        return viewModel
    }

    private func coordinator(type: DatabaseType, fields: [String: String]) -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.name = "cluster"
        coordinator.network.type = type
        coordinator.network.additionalFieldValues = fields
        return coordinator
    }

    private func edits(type: DatabaseType, fields: [String: String]) -> ConnectionFormEdits {
        coordinator(type: type, fields: fields).buildEdits()
    }

    @Test("An Elasticsearch connection saved with Host and Port opens with them as its node list")
    func elasticsearchSeedsFromHostAndPort() {
        let viewModel = loaded(DatabaseConnection(name: "es", host: "es1.example", port: 9_201, type: .elasticsearch))
        #expect(viewModel.additionalFieldValues["esHosts"] == "es1.example:9201")
    }

    @Test("A Kafka connection opens with the broker it dials, not a blank list")
    func kafkaSeedsFromHostAndPort() {
        let viewModel = loaded(DatabaseConnection(name: "k", host: "broker1.example", port: 9_092, type: .kafka))
        #expect(viewModel.additionalFieldValues["kafkaBootstrapServers"] == "broker1.example:9092")
    }

    @Test("A Kafka list saved as extra brokers shows the hidden Host as its last row")
    func kafkaLegacyListKeepsHost() {
        let viewModel = loaded(DatabaseConnection(
            name: "k",
            host: "broker1.example",
            port: 9_092,
            type: .kafka,
            additionalFields: ["kafkaBootstrapServers": "b2.example:9092"]
        ))
        #expect(viewModel.additionalFieldValues["kafkaBootstrapServers"] == "b2.example:9092,broker1.example:9092")
    }

    @Test("A Host the form filled in while it was hidden is not added to a saved list")
    func defaultHostStaysOut() {
        let viewModel = loaded(DatabaseConnection(
            name: "es",
            host: "localhost",
            port: 9_200,
            type: .elasticsearch,
            additionalFields: ["esHosts": "es1.example:9200,es2.example:9200"]
        ))
        #expect(viewModel.additionalFieldValues["esHosts"] == "es1.example:9200,es2.example:9200")
    }

    @Test("A legacy Kafka broker on localhost with its own port stays in the list")
    func legacyLocalhostOnOtherPortStays() {
        let viewModel = loaded(DatabaseConnection(
            name: "k",
            host: "localhost",
            port: 9_093,
            type: .kafka,
            additionalFields: ["kafkaBootstrapServers": "broker2.example:9092"]
        ))
        #expect(viewModel.additionalFieldValues["kafkaBootstrapServers"] == "broker2.example:9092,localhost:9093")
    }

    @Test("Clearing every row connects to the placeholder, not the Host the list hid")
    func clearedListUsesDefaults() {
        let form = coordinator(type: .elasticsearch, fields: ["esHosts": " , "])
        form.network.host = "old.example"
        form.network.port = "9300"
        let result = form.buildEdits()
        #expect(result.host == "localhost")
        #expect(result.port == 9_200)
        #expect(result.additionalFields["esHosts"] == "")
    }

    @Test("Redis lists belong to one mode and are never seeded from Host")
    func redisListsAreNotSeeded() {
        let viewModel = loaded(DatabaseConnection(name: "r", host: "cache.example", port: 6_379, type: .redis))
        #expect((viewModel.additionalFieldValues["redisClusterHosts"] ?? "").isEmpty)
        #expect((viewModel.additionalFieldValues["redisSentinelHosts"] ?? "").isEmpty)
    }

    @Test("Saving pasted node URLs stores host:port entries and takes Host and Port from the first")
    func elasticsearchSaveNormalizesNodes() {
        let result = edits(
            type: .elasticsearch,
            fields: ["esHosts": "https://111.111.111.111:9200,https://111.111.111.112:9200,https://[fd00::3]:9200"]
        )
        #expect(result.additionalFields["esHosts"] == "111.111.111.111:9200,111.111.111.112:9200,[fd00::3]:9200")
        #expect(result.host == "111.111.111.111")
        #expect(result.port == 9_200)
    }

    @Test("A blank row is dropped, not saved as localhost")
    func blankRowIsDropped() {
        let result = edits(type: .mongodb, fields: ["mongoHosts": ",a.example:27017, ,b.example"])
        #expect(result.additionalFields["mongoHosts"] == "a.example:27017,b.example:27017")
        #expect(result.host == "a.example")
        #expect(result.port == 27_017)
    }

    @Test("A row that is not a host blocks Save instead of being dropped")
    func invalidRowIsAnIssue() {
        let issues = coordinator(type: .elasticsearch, fields: ["esHosts": "es1:9200,es2:abc"]).network.validationIssues
        #expect(issues.count == 1)
        #expect(issues.first?.contains("es2:abc") == true)
    }

    @Test("An https:// node needs SSL turned on, or its credentials would go over plain HTTP")
    func httpsNodeNeedsSSL() {
        let form = coordinator(type: .elasticsearch, fields: ["esHosts": "https://10.0.0.1:9200"])
        form.ssl.select(.disabled)
        #expect(form.network.validationIssues.contains { $0.contains("https://10.0.0.1:9200") })

        form.ssl.select(.required)
        #expect(form.network.validationIssues.isEmpty)
    }

    @Test("Switching another type's Host to Elasticsearch carries it into the node list")
    func typeChangeSeedsTheList() {
        let form = ConnectionFormCoordinator(connectionId: nil)
        form.start()
        form.network.host = "db.example"
        form.network.setType(.elasticsearch)
        #expect(form.network.additionalFieldValues["esHosts"] == "db.example:9200")
    }

    @Test("Kafka Host and Port follow the first bootstrap server")
    func kafkaHostFollowsFirstServer() {
        let result = edits(type: .kafka, fields: ["kafkaBootstrapServers": "b1.example:9093,b2.example:9092"])
        #expect(result.host == "b1.example")
        #expect(result.port == 9_093)
    }
}
