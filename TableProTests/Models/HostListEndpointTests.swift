//
//  HostListEndpointTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct HostListEndpointTests {
    @Test("A pasted URL loses its scheme and keeps its port")
    func pastedURL() {
        #expect(HostListEndpoint.parse("https://111.111.111.111:9200", defaultPort: 9_200)
            == HostListEndpoint(host: "111.111.111.111", port: 9_200))
        #expect(HostListEndpoint.parse(" http://es1.example:9201/ ", defaultPort: 9_200)
            == HostListEndpoint(host: "es1.example", port: 9_201))
    }

    @Test("A URL with no port names the scheme's port")
    func urlWithoutPort() {
        #expect(HostListEndpoint.parse("https://cluster.example.cloud", defaultPort: 9_200)?.port == 443)
        #expect(HostListEndpoint.parse("http://es1", defaultPort: 9_200)?.port == 80)
    }

    @Test("A bare host gets the default port")
    func bareHost() {
        #expect(HostListEndpoint.parse("es1", defaultPort: 9_200) == HostListEndpoint(host: "es1", port: 9_200))
    }

    @Test("IPv6 with and without brackets")
    func ipv6() {
        #expect(HostListEndpoint.parse("[::1]:9201", defaultPort: 9_200) == HostListEndpoint(host: "::1", port: 9_201))
        #expect(HostListEndpoint.parse("[fe80::1]", defaultPort: 9_200) == HostListEndpoint(host: "fe80::1", port: 9_200))
        #expect(HostListEndpoint.parse("2001:db8::10", defaultPort: 9_200)
            == HostListEndpoint(host: "2001:db8::10", port: 9_200))
        #expect(HostListEndpoint(host: "::1", port: 9_200).entry == "[::1]:9200")
    }

    @Test("Blank entries and other schemes are not endpoints")
    func rejected() {
        #expect(HostListEndpoint.parse("  ", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse(":9200", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse("[]:9200", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse("mongodb://a:27017", defaultPort: 27_017) == nil)
        #expect(HostListEndpoint.parse("es1:abc", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse("es1:0", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse("[::1", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse("https://user:secret@es1:9200", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parse("https://es1:9200/prefix", defaultPort: 9_200) == nil)
        #expect(HostListEndpoint.parseList("a:1,, ,b:2,", defaultPort: 9).map(\.entry) == ["a:1", "b:2"])
    }

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
