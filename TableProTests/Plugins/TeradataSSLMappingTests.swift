import Foundation
import TableProPluginKit
import TableProTeradataCore
import Testing

struct TeradataSSLMappingTests {
    @Test("Verify CA with an empty or blank CA path is refused before any options are built")
    func verifyCaWithoutCertificateIsRefused() {
        for path in ["", "   "] {
            let error = #expect(throws: TeradataSSLConfigurationError.self) {
                _ = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .verifyCa, caCertificatePath: path))
            }
            #expect(error == .verifyCaNeedsCertificate)
        }
    }

    @Test("The refusal names the missing CA certificate")
    func refusalMessageNamesTheCertificate() {
        let message = TeradataSSLConfigurationError.verifyCaNeedsCertificate.pluginErrorMessage
        #expect(message.contains("CA certificate"))
        #expect(TeradataSSLConfigurationError.verifyCaNeedsCertificate.errorDescription == message)
    }

    @Test("Verify CA with a CA path checks the chain but not the hostname")
    func verifyCaWithCertificateMaps() throws {
        let options = try TeradataSSLMapping.tlsOptions(
            for: SSLConfiguration(mode: .verifyCa, caCertificatePath: "/certs/ca.pem")
        )
        #expect(options.verifiesCertificate)
        #expect(!options.verifiesHostname)
        #expect(options.caCertificatePath == "/certs/ca.pem")
        #expect(options.modeLabel == "VERIFY-CA")
    }

    @Test("Verify Identity with no CA path is not refused")
    func verifyIdentityWithoutCertificateMaps() throws {
        let options = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .verifyIdentity))
        #expect(options.verifiesCertificate)
        #expect(options.verifiesHostname)
        #expect(options.caCertificatePath.isEmpty)
    }

    @Test("Disabled and Required ignore the CA path")
    func nonVerifyingModesAreNotRefused() throws {
        let disabled = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .disabled))
        #expect(!disabled.enabled)
        let required = try TeradataSSLMapping.tlsOptions(for: SSLConfiguration(mode: .required))
        #expect(required.enabled)
        #expect(!required.verifiesCertificate)
    }
}
