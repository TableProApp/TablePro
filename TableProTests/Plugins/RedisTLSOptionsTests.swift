import Foundation
import TableProPluginKit
import Testing

struct RedisTLSOptionsTests {
    @Test("Verify Identity checks the certificate against the host being dialed")
    func verifyIdentityChecksHostname() throws {
        let ssl = SSLConfiguration(mode: .verifyIdentity, caCertificatePath: "/certs/ca.pem")
        let options = try #require(RedisTLSOptions.make(sslConfig: ssl, host: "redis.example.com"))
        #expect(options.verifiesCertificate)
        #expect(options.checksHostname)
        #expect(options.expectedHost == "redis.example.com")
        #expect(options.serverName == "redis.example.com")
        #expect(options.caCertificatePath == "/certs/ca.pem")
    }

    @Test("Verify Identity checks an IP address host too")
    func verifyIdentityChecksIPAddress() throws {
        let ssl = SSLConfiguration(mode: .verifyIdentity)
        let options = try #require(RedisTLSOptions.make(sslConfig: ssl, host: "10.0.0.5"))
        #expect(options.checksHostname)
        #expect(options.expectedHost == "10.0.0.5")
    }

    @Test("Verify CA checks the chain but not the hostname")
    func verifyCaSkipsHostname() throws {
        let ssl = SSLConfiguration(mode: .verifyCa, caCertificatePath: "/certs/ca.pem")
        let options = try #require(RedisTLSOptions.make(sslConfig: ssl, host: "redis.example.com"))
        #expect(options.verifiesCertificate)
        #expect(options.checksHostname == false)
        #expect(options.expectedHost == nil)
        #expect(options.caCertificatePath == "/certs/ca.pem")
    }

    @Test("Required encrypts without verifying the certificate or the hostname")
    func requiredVerifiesNothing() throws {
        let ssl = SSLConfiguration(mode: .required, caCertificatePath: "/certs/ca.pem")
        let options = try #require(RedisTLSOptions.make(sslConfig: ssl, host: "redis.example.com"))
        #expect(options.verifiesCertificate == false)
        #expect(options.checksHostname == false)
        #expect(options.caCertificatePath == nil)
        #expect(options.serverName == "redis.example.com")
    }

    @Test("Preferred encrypts without verifying the certificate or the hostname")
    func preferredVerifiesNothing() throws {
        let options = try #require(
            RedisTLSOptions.make(sslConfig: SSLConfiguration(mode: .preferred), host: "redis.example.com")
        )
        #expect(options.verifiesCertificate == false)
        #expect(options.checksHostname == false)
    }

    @Test("Disabled produces no TLS options")
    func disabledHasNoOptions() {
        let ssl = SSLConfiguration(mode: .disabled, caCertificatePath: "/certs/ca.pem")
        #expect(RedisTLSOptions.make(sslConfig: ssl, host: "redis.example.com") == nil)
    }

    @Test("empty certificate paths are left unset")
    func emptyPathsAreUnset() throws {
        let options = try #require(
            RedisTLSOptions.make(sslConfig: SSLConfiguration(mode: .verifyIdentity), host: "redis.example.com")
        )
        #expect(options.caCertificatePath == nil)
        #expect(options.clientCertificatePath == nil)
        #expect(options.clientKeyPath == nil)
    }

    @Test("client certificate and key are passed through in every encrypted mode")
    func clientCertificatePassedThrough() throws {
        let ssl = SSLConfiguration(
            mode: .required,
            clientCertificatePath: "/certs/client.pem",
            clientKeyPath: "/certs/client.key"
        )
        let options = try #require(RedisTLSOptions.make(sslConfig: ssl, host: "redis.example.com"))
        #expect(options.clientCertificatePath == "/certs/client.pem")
        #expect(options.clientKeyPath == "/certs/client.key")
    }
}
