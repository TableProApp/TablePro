import Foundation
import TableProPluginKit
import Testing

struct DriverConnectionConfigTunneledServerNameTests {
    private func config(host: String, preTunnelHost: String?) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: host,
            port: 49_152,
            username: "",
            password: "",
            database: "",
            additionalFields: preTunnelHost.map { ["preTunnelHost": $0] } ?? [:]
        )
    }

    @Test("A loopback dial names the server behind the tunnel", arguments: ["127.0.0.1", "::1", "localhost", "LOCALHOST"])
    func loopbackDialReturnsThePreTunnelHost(host: String) {
        #expect(config(host: host, preTunnelHost: " db.example.com\n").tunneledServerName == "db.example.com")
    }

    @Test("A direct dial is checked against its own host, whatever a stored field says")
    func directDialIgnoresAStoredPreTunnelHost() {
        #expect(config(host: "db.example.com", preTunnelHost: "attacker.example.com").tunneledServerName == nil)
        #expect(config(host: "10.0.0.5", preTunnelHost: "db.example.com").tunneledServerName == nil)
        #expect(config(host: "127.0.0.2", preTunnelHost: "db.example.com").tunneledServerName == nil)
    }

    @Test("A blank or missing pre-tunnel host gives no name")
    func blankPreTunnelHostGivesNoName() {
        #expect(config(host: "127.0.0.1", preTunnelHost: nil).tunneledServerName == nil)
        #expect(config(host: "127.0.0.1", preTunnelHost: "").tunneledServerName == nil)
        #expect(config(host: "127.0.0.1", preTunnelHost: "  \n").tunneledServerName == nil)
    }
}
