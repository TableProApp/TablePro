import Foundation
@testable import TableProMobile
import Testing

@Suite("PKCS#12 import")
struct PKCS12ImporterTests {
    @Test("an empty password is rejected before the file is read")
    func emptyPasswordRejected() {
        #expect(throws: PKCS12ImportError.passwordRequired) {
            try PKCS12Importer.material(from: PKCS12Fixture.data, password: "")
        }
    }

    @Test("a wrong password fails without crashing")
    func wrongPasswordFails() {
        #expect(throws: (any Error).self) {
            try PKCS12Importer.material(from: PKCS12Fixture.data, password: "not-the-password")
        }
    }

    @Test("data that is not a certificate file fails without crashing")
    func garbageInputFails() {
        #expect(throws: (any Error).self) {
            try PKCS12Importer.material(from: Data("not a p12".utf8), password: "tablepro")
        }
    }

    @Test("a real certificate file yields a PEM certificate and key the drivers can use")
    func importsRealCertificate() throws {
        let material = try PKCS12Importer.material(
            from: PKCS12Fixture.data,
            password: PKCS12Fixture.password
        )

        let certificates = PEMDocument.inspect(material.certificateChainPEM)
        #expect(certificates.certificates.count >= 1)
        #expect(certificates.privateKeys.isEmpty)

        let key = PEMDocument.inspect(material.privateKeyPEM)
        #expect(key.privateKeys.count == 1)
        #expect(key.certificates.isEmpty)
        #expect(!key.usesPassphrase)
    }

    @Test("an RSA key keeps the PKCS#1 label that matches its contents")
    func rsaKeyKeepsMatchingLabel() throws {
        let material = try PKCS12Importer.material(
            from: PKCS12Fixture.data,
            password: PKCS12Fixture.password
        )

        #expect(material.privateKeyPEM.contains("-----BEGIN RSA PRIVATE KEY-----"))
        #expect(!material.privateKeyPEM.contains("-----BEGIN PRIVATE KEY-----"))
    }

    @Test("the certificate's common name is carried through for display")
    func exposesCommonName() throws {
        let material = try PKCS12Importer.material(
            from: PKCS12Fixture.data,
            password: PKCS12Fixture.password
        )

        #expect(material.commonName == PKCS12Fixture.commonName)
    }
}
