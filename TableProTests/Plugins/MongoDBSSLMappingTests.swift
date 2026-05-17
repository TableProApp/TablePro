import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MongoDBSSLMapping")
struct MongoDBSSLMappingTests {
    @Test("Disabled returns empty parameter list")
    func testDisabled() {
        let params = MongoDBSSLMapping.uriParameters(for: SSLConfiguration(mode: .disabled))
        #expect(params.isEmpty)
    }

    @Test("Preferred enables TLS with invalid-cert tolerance")
    func testPreferred() {
        let params = MongoDBSSLMapping.uriParameters(for: SSLConfiguration(mode: .preferred))
        #expect(params.contains("tls=true"))
        #expect(params.contains("tlsAllowInvalidCertificates=true"))
    }

    @Test("Required enables TLS with invalid-cert tolerance (same as Preferred for this driver)")
    func testRequired() {
        let params = MongoDBSSLMapping.uriParameters(for: SSLConfiguration(mode: .required))
        #expect(params.contains("tls=true"))
        #expect(params.contains("tlsAllowInvalidCertificates=true"))
    }

    @Test("Verify CA enables TLS with hostname tolerance only")
    func testVerifyCA() {
        let config = SSLConfiguration(mode: .verifyCa, caCertificatePath: "/tmp/ca.pem")
        let params = MongoDBSSLMapping.uriParameters(for: config)
        #expect(params.contains("tls=true"))
        #expect(params.contains("tlsAllowInvalidHostnames=true"))
        #expect(params.contains { $0.hasPrefix("tlsCAFile=") })
    }

    @Test("Verify Identity enables TLS with full validation")
    func testVerifyIdentity() {
        let config = SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/tmp/ca.pem")
        let params = MongoDBSSLMapping.uriParameters(for: config)
        #expect(params.contains("tls=true"))
        #expect(!params.contains("tlsAllowInvalidCertificates=true"))
        #expect(!params.contains("tlsAllowInvalidHostnames=true"))
        #expect(params.contains { $0.hasPrefix("tlsCAFile=") })
    }

    @Test("Client certificate path is included when set")
    func testClientCert() {
        let config = SSLConfiguration(
            mode: .verifyIdentity,
            caCertificatePath: "/tmp/ca.pem",
            clientCertificatePath: "/tmp/client.pem"
        )
        let params = MongoDBSSLMapping.uriParameters(for: config)
        #expect(params.contains { $0.hasPrefix("tlsCertificateKeyFile=") })
    }

    @Test("Paths with special characters are URL-encoded")
    func testPathEncoding() {
        let config = SSLConfiguration(
            mode: .verifyIdentity,
            caCertificatePath: "/path with spaces/ca.pem"
        )
        let params = MongoDBSSLMapping.uriParameters(for: config)
        let caParam = params.first { $0.hasPrefix("tlsCAFile=") }
        #expect(caParam?.contains(" ") == false)
        #expect(caParam?.contains("%20") == true)
    }
}
