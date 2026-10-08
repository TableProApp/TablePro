//
//  KafkaBootstrapEndpointsTests.swift
//  TableProTests
//

import Foundation
import Testing

struct KafkaBootstrapEndpointsTests {
    @Test("The list is dialed before a hidden Host, which an older list left out")
    func listComesBeforeHiddenHost() {
        let endpoints = KafkaConnectionField.bootstrapEndpoints(
            host: "localhost",
            port: 9_092,
            fields: ["kafkaBootstrapServers": "b1.example:9093,b2.example"],
            defaultPort: 9_092
        )
        #expect(endpoints == [
            KafkaEndpoint(host: "b1.example", port: 9_093),
            KafkaEndpoint(host: "b2.example", port: 9_092),
            KafkaEndpoint(host: "localhost", port: 9_092),
        ])
    }

    @Test("A Host the list already names is not dialed twice")
    func listedHostIsNotRepeated() {
        let endpoints = KafkaConnectionField.bootstrapEndpoints(
            host: "b2.example",
            port: 9_092,
            fields: ["kafkaBootstrapServers": "b2.example:9092,b3.example:9092"],
            defaultPort: 9_092
        )
        #expect(endpoints.count == 2)
    }

    @Test("Host and Port are dialed when the list is empty, as behind a tunnel")
    func emptyListUsesHost() {
        let endpoints = KafkaConnectionField.bootstrapEndpoints(
            host: "127.0.0.1",
            port: 50_123,
            fields: [:],
            defaultPort: 9_092
        )
        #expect(endpoints == [KafkaEndpoint(host: "127.0.0.1", port: 50_123)])
    }

    @Test("Each remaining bootstrap server gets an equal share of the time left")
    func deadlineIsShared() {
        let deadline = KafkaConnectDeadline(milliseconds: 9_000, now: 100)
        #expect(deadline.remainingMilliseconds(sharedBy: 3, now: 100) == 3_000)
        #expect(deadline.remainingMilliseconds(sharedBy: 1, now: 106) == 3_000)
        #expect(deadline.remainingMilliseconds(sharedBy: 2, now: 109.5) == nil)
    }
}
