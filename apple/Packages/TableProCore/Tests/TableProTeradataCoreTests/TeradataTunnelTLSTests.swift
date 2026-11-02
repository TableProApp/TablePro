import TableProTeradataCore
import Testing

struct TeradataTunnelTLSTests {
    @Test("Behind a tunnel a mode that demands TLS is refused, since TLS would dial this Mac's port 443")
    func requiredTLSIsRefused() {
        let required = TeradataTLSOptions(enabled: true, allowPlaintextFallback: false, modeLabel: "REQUIRE")
        #expect(required.throughTunnel() == nil)
        let verified = TeradataTLSOptions(enabled: true, verifiesCertificate: true, verifiesHostname: true)
        #expect(verified.throughTunnel() == nil)
    }

    @Test("Behind a tunnel Preferred goes through the forward without TLS")
    func preferredSkipsTLS() throws {
        let preferred = TeradataTLSOptions(enabled: true, allowPlaintextFallback: true, modeLabel: "PREFER")
        let options = try #require(preferred.throughTunnel())
        #expect(!options.enabled)
    }

    @Test("Behind a tunnel Disabled stays as it is")
    func disabledIsKept() throws {
        let options = try #require(TeradataTLSOptions.disabled.throughTunnel())
        #expect(!options.enabled)
    }
}
