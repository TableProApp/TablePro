import Foundation
@testable import TableProMobile
import Testing

@Suite("LocalNetworkPermission host classification")
struct LocalNetworkPermissionTests {
    @Test("Loopback names and addresses are recognised", arguments: [
        "localhost",
        "LOCALHOST",
        "db.localhost",
        "127.0.0.1",
        "127.1.2.3",
        "::1",
        "::ffff:127.0.0.1"
    ])
    func loopbackIsRecognised(host: String) {
        #expect(LocalNetworkPermission.isLoopback(host))
    }

    @Test("Everything reachable off-device is not loopback", arguments: [
        "192.168.1.10",
        "10.0.0.5",
        "8.8.8.8",
        "128.30.2.121",
        "nas.local",
        "db.corp.internal",
        "::",
        "2001:4860:4860::8888",
        ""
    ])
    func nonLoopbackIsNotSkipped(host: String) {
        #expect(!LocalNetworkPermission.isLoopback(host))
    }

    @Test("A LAN on public addresses is probed rather than skipped")
    func publicAddressLANIsStillProbed() {
        // The old classifier skipped anything outside RFC1918, which meant a
        // directly attached network using public addresses never reached the
        // permission check at all.
        #expect(!LocalNetworkPermission.isLoopback("128.30.2.121"))
        #expect(!LocalNetworkPermission.isLoopback("nas.lan"))
    }

    @Test("The messaging hint still recognises the common private ranges", arguments: [
        "10.0.0.5",
        "172.16.4.1",
        "172.31.255.254",
        "192.168.0.1",
        "169.254.1.1",
        "nas.local",
        "fd00::1",
        "fe80::1"
    ])
    func hintMatchesPrivateRanges(host: String) {
        #expect(LocalNetworkPermission.mayBeLocalNetworkHost(host))
    }

    @Test("The messaging hint does not claim public or loopback hosts", arguments: [
        "8.8.8.8",
        "128.30.2.121",
        "172.32.0.1",
        "172.15.0.1",
        "localhost",
        "127.0.0.1",
        "2001:4860:4860::8888",
        "db.example.com"
    ])
    func hintExcludesPublicAndLoopback(host: String) {
        #expect(!LocalNetworkPermission.mayBeLocalNetworkHost(host))
    }
}
