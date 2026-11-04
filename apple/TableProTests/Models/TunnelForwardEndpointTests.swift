//
//  TunnelForwardEndpointTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TunnelForwardEndpointTests {
    @Test("The tunnel forwards to the first node of a pasted URL list")
    func tunnelUsesFirstParsedNode() {
        let connection = DatabaseConnection(
            name: "es",
            host: "",
            port: 9_200,
            type: .elasticsearch,
            additionalFields: ["esHosts": "https://10.0.0.1:9201,https://10.0.0.2:9200"]
        )
        #expect(connection.tunnelForwardEndpoint.host == "10.0.0.1")
        #expect(connection.tunnelForwardEndpoint.port == 9_201)
    }

    private func duckdb(mode: String, fields: [String: String] = [:]) -> DatabaseConnection {
        DatabaseConnection(
            name: "quack",
            host: "localhost",
            port: 9_494,
            type: .duckdb,
            additionalFields: fields.merging(["duckdbMode": mode]) { _, mode in mode }
        )
    }

    @Test("A DuckDB Remote row's server is its own Host and Port fields, never the built-in placeholder")
    func duckdbRemoteServerIsItsFields() {
        let connection = duckdb(mode: "remote", fields: ["duckdbHost": " 192.168.1.20 ", "duckdbPort": "9500"])

        #expect(connection.activeServerEndpointFields == ServerEndpointFields(hostFieldId: "duckdbHost", portFieldId: "duckdbPort"))
        #expect(connection.serverEndpoint.host == "192.168.1.20")
        #expect(connection.serverEndpoint.port == 9_500)
        #expect(connection.tunnelForwardEndpoint.host == "192.168.1.20")
        #expect(connection.tunnelForwardEndpoint.port == 9_500)
        #expect(connection.timeoutEndpointName == "192.168.1.20")
    }

    @Test("An empty DuckDB port forwards to the port its field shows")
    func duckdbEmptyPortUsesTheFieldDefault() {
        let connection = duckdb(mode: "remote", fields: ["duckdbHost": "quack.internal", "duckdbPort": ""])

        #expect(connection.tunnelForwardEndpoint.host == "quack.internal")
        #expect(connection.tunnelForwardEndpoint.port == 9_494)
    }

    @Test("A DuckDB Local File row keeps no server, whatever its hidden Remote fields still hold")
    func duckdbLocalHasNoServerFields() {
        let connection = duckdb(mode: "local", fields: ["duckdbHost": "192.168.1.20", "duckdbPort": "9500"])

        #expect(connection.activeServerEndpointFields == nil)
        #expect(!connection.dialsForwardedEndpoint)
        #expect(connection.serverEndpoint.host == "localhost")
    }

    @Test("A network row's server stays its Host and Port")
    func networkRowKeepsBuiltInEndpoint() {
        let connection = DatabaseConnection(name: "pg", host: "db.internal", port: 5_433, type: .postgresql)

        #expect(connection.activeServerEndpointFields == nil)
        #expect(connection.dialsForwardedEndpoint)
        #expect(connection.serverEndpoint.host == "db.internal")
        #expect(connection.serverEndpoint.port == 5_433)
    }

    @Test("A type the registry does not know keeps forwarding its Host and Port")
    func unknownTypeStillForwards() {
        let connection = DatabaseConnection(
            name: "future", host: "db.internal", port: 7_000, type: DatabaseType(rawValue: "NoSuchEngine")
        )

        #expect(connection.dialsForwardedEndpoint)
        #expect(connection.tunnelForwardEndpoint.host == "db.internal")
    }
}
