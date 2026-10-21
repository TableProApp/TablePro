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
}
