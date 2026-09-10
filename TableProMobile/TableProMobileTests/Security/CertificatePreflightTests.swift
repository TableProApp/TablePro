import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Certificate preflight")
struct CertificatePreflightTests {
    private func temporaryFile() -> String {
        let path = NSTemporaryDirectory() + "tablepro-preflight-\(UUID().uuidString).pem"
        FileManager.default.createFile(atPath: path, contents: Data("pem".utf8))
        return path
    }

    @Test("a disabled connection is never blocked")
    func disabledPasses() throws {
        try CertificatePreflight.validate(DriverSSLConfiguration(
            mode: .disable,
            clientCertificatePath: "/gone.pem"
        ))
    }

    @Test("a connection with no certificates passes")
    func noCertificatesPasses() throws {
        try CertificatePreflight.validate(DriverSSLConfiguration(mode: .require))
    }

    @Test("a missing client certificate is reported instead of silently dropped")
    func missingClientCertificate() {
        #expect(throws: CertificatePreflightError.fileMissing(.clientCertificate)) {
            try CertificatePreflight.validate(DriverSSLConfiguration(
                mode: .require,
                clientCertificatePath: "/gone.pem",
                clientKeyPath: "/gone.key"
            ))
        }
    }

    @Test("a missing CA is reported when the mode verifies it")
    func missingCA() {
        #expect(throws: CertificatePreflightError.fileMissing(.certificateAuthority)) {
            try CertificatePreflight.validate(DriverSSLConfiguration(
                mode: .verifyFull,
                caCertificatePath: "/gone.pem"
            ))
        }
    }

    @Test("a certificate without its key is refused before connecting")
    func certificateWithoutKey() {
        let certPath = temporaryFile()
        defer { try? FileManager.default.removeItem(atPath: certPath) }

        #expect(throws: CertificatePreflightError.clientCertificateWithoutKey) {
            try CertificatePreflight.validate(DriverSSLConfiguration(
                mode: .require,
                clientCertificatePath: certPath
            ))
        }
    }

    @Test("a key without its certificate is refused before connecting")
    func keyWithoutCertificate() {
        let keyPath = temporaryFile()
        defer { try? FileManager.default.removeItem(atPath: keyPath) }

        #expect(throws: CertificatePreflightError.clientKeyWithoutCertificate) {
            try CertificatePreflight.validate(DriverSSLConfiguration(
                mode: .require,
                clientKeyPath: keyPath
            ))
        }
    }

    @Test("a complete pair passes")
    func completePairPasses() throws {
        let certPath = temporaryFile()
        let keyPath = temporaryFile()
        defer {
            try? FileManager.default.removeItem(atPath: certPath)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        try CertificatePreflight.validate(DriverSSLConfiguration(
            mode: .require,
            clientCertificatePath: certPath,
            clientKeyPath: keyPath
        ))
    }
}
