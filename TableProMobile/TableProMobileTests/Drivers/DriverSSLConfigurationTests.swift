import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("DriverSSLConfiguration")
struct DriverSSLConfigurationTests {
    @Test("legacy bool with no configuration maps to require when enabled")
    func legacyBoolEnabled() {
        let ssl = DriverSSLConfiguration(sslEnabled: true, configuration: nil)
        #expect(ssl.mode == .require)
        #expect(ssl.isEnabled)
        #expect(!ssl.verifiesCertificate)
        #expect(ssl.caCertificatePath == nil)
    }

    @Test("legacy bool with no configuration maps to disable when off")
    func legacyBoolDisabled() {
        let ssl = DriverSSLConfiguration(sslEnabled: false, configuration: nil)
        #expect(ssl.mode == .disable)
        #expect(!ssl.isEnabled)
    }

    @Test("configuration mode is authoritative over the legacy bool")
    func configurationWins() {
        let config = SSLConfiguration(mode: .verifyFull, caCertificatePath: "/tmp/ca.pem")
        let ssl = DriverSSLConfiguration(sslEnabled: false, configuration: config)
        #expect(ssl.mode == .verifyFull)
        #expect(ssl.verifiesCertificate)
        #expect(ssl.verifiesHostname)
        #expect(ssl.caCertificatePath == "/tmp/ca.pem")
    }

    @Test("verifiesCertificate is true only for verify modes")
    func verifiesCertificate() {
        #expect(!DriverSSLConfiguration(mode: .disable).verifiesCertificate)
        #expect(!DriverSSLConfiguration(mode: .require).verifiesCertificate)
        #expect(DriverSSLConfiguration(mode: .verifyCa).verifiesCertificate)
        #expect(DriverSSLConfiguration(mode: .verifyFull).verifiesCertificate)
    }

    @Test("verifiesHostname is true only for verifyFull")
    func verifiesHostname() {
        #expect(!DriverSSLConfiguration(mode: .verifyCa).verifiesHostname)
        #expect(DriverSSLConfiguration(mode: .verifyFull).verifiesHostname)
    }

    @Test("postgres sslmode mirrors libpq mapping")
    func postgresMapping() {
        #expect(DriverSSLConfiguration(mode: .disable).postgresSSLMode == "disable")
        #expect(DriverSSLConfiguration(mode: .require).postgresSSLMode == "require")
        #expect(DriverSSLConfiguration(mode: .verifyCa).postgresSSLMode == "verify-ca")
        #expect(DriverSSLConfiguration(mode: .verifyFull).postgresSSLMode == "verify-full")
    }

    @Test("freetds encryption flag never downgrades verify modes to plaintext")
    func freetdsMapping() {
        #expect(DriverSSLConfiguration(mode: .disable).freetdsEncryptionFlag == "off")
        #expect(DriverSSLConfiguration(mode: .require).freetdsEncryptionFlag == "require")
        #expect(DriverSSLConfiguration(mode: .verifyCa).freetdsEncryptionFlag == "require")
        #expect(DriverSSLConfiguration(mode: .verifyFull).freetdsEncryptionFlag == "require")
    }

    @Test("CA path is ignored for non-verify modes")
    func caIgnoredWithoutVerification() {
        let path = NSTemporaryDirectory() + "tablepro-ca-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: path, contents: Data("cert".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let requireMode = DriverSSLConfiguration(mode: .require, caCertificatePath: path)
        #expect(requireMode.existingCACertificatePath == nil)
    }

    @Test("CA path is used for verify modes only when the file exists on device")
    func caUsedWhenPresent() {
        let path = NSTemporaryDirectory() + "tablepro-ca-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: path, contents: Data("cert".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let present = DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: path)
        #expect(present.existingCACertificatePath == path)

        let missing = DriverSSLConfiguration(mode: .verifyFull, caCertificatePath: "/does/not/exist.pem")
        #expect(missing.existingCACertificatePath == nil)
    }
}
