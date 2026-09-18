import Foundation
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import Testing

@Suite("Oracle TLS description mapping")
struct OracleSSLMappingTests {
    @Test("Every SSL mode maps to the matching Oracle TLS mode")
    func modesMap() {
        #expect(DriverSSLConfiguration(mode: .disable).oracleTLSDescription.mode == .disabled)
        #expect(DriverSSLConfiguration(mode: .require).oracleTLSDescription.mode == .required)
        #expect(DriverSSLConfiguration(mode: .verifyCa).oracleTLSDescription.mode == .verifyCA)
        #expect(DriverSSLConfiguration(mode: .verifyFull).oracleTLSDescription.mode == .verifyIdentity)
    }

    @Test("Only the verify modes are treated as verifying the certificate")
    func verifyModes() {
        #expect(!DriverSSLConfiguration(mode: .require).oracleTLSDescription.verifiesCertificate)
        #expect(DriverSSLConfiguration(mode: .verifyCa).oracleTLSDescription.verifiesCertificate)
        #expect(DriverSSLConfiguration(mode: .verifyFull).oracleTLSDescription.verifiesCertificate)
    }

    @Test("Client certificate and key paths survive the trip from a stored connection")
    func clientMaterialIsCarried() {
        let configuration = SSLConfiguration(
            mode: .verifyFull,
            caCertificatePath: "/certs/ca.pem",
            clientCertificatePath: "/certs/client.pem",
            clientKeyPath: "/certs/client.key"
        )
        let description = DriverSSLConfiguration(sslEnabled: true, configuration: configuration)
            .oracleTLSDescription
        #expect(description.caCertificatePath == "/certs/ca.pem")
        #expect(description.clientCertificatePath == "/certs/client.pem")
        #expect(description.clientKeyPath == "/certs/client.key")
    }

    @Test("Empty stored paths are absent rather than empty strings")
    func emptyPathsBecomeNil() {
        let configuration = SSLConfiguration(mode: .require, caCertificatePath: "")
        let description = DriverSSLConfiguration(sslEnabled: true, configuration: configuration)
            .oracleTLSDescription
        #expect(description.caCertificatePath == nil)
    }

    @Test("A connection with no SSL configuration carries no certificate paths")
    func legacyBoolCarriesNoPaths() {
        let description = DriverSSLConfiguration(sslEnabled: true, configuration: nil).oracleTLSDescription
        #expect(description.mode == .required)
        #expect(description.caCertificatePath == nil)
        #expect(description.clientCertificatePath == nil)
        #expect(description.clientKeyPath == nil)
    }
}
