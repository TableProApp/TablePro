import Foundation
import TableProDuckDBCore
import Testing

private let systemBundle = Data("""
    -----BEGIN CERTIFICATE-----
    UFVCTElDLVJPT1Q=
    -----END CERTIFICATE-----
    """.utf8)

private let privateCA = Data("""
    -----BEGIN CERTIFICATE-----
    UFJJVkFURS1DQQ==
    -----END CERTIFICATE-----

    """.utf8)

struct QuackTrustBundleTests {
    @Test("The bundle keeps httpfs's default and adds the CA after it, so public HTTPS still verifies")
    func combinedKeepsTheDefaultFirst() throws {
        let bundle = try QuackTrustBundle.combined(
            defaultBundle: systemBundle,
            caCertificate: privateCA,
            caCertificatePath: "/Users/me/rootCA.pem"
        )
        var expected = systemBundle
        expected.append(UInt8(ascii: "\n"))
        expected.append(privateCA)
        #expect(bundle == expected)
    }

    @Test("A default bundle that ends in a newline gets no second one")
    func noDoubledNewline() throws {
        var system = systemBundle
        system.append(UInt8(ascii: "\n"))
        let bundle = try QuackTrustBundle.combined(defaultBundle: system, caCertificate: privateCA, caCertificatePath: "ca.pem")
        #expect(bundle == system + privateCA)
    }

    @Test("With no default bundle on the Mac, the CA alone is what httpfs would have trusted")
    func noDefaultBundle() throws {
        let bundle = try QuackTrustBundle.combined(defaultBundle: nil, caCertificate: privateCA, caCertificatePath: "ca.pem")
        #expect(bundle == privateCA)
    }

    @Test("A CA after other text in its file is still PEM")
    func pemAfterText() throws {
        let annotated = Data("Subject: CN=Private CA\n".utf8) + privateCA
        let bundle = try QuackTrustBundle.combined(defaultBundle: nil, caCertificate: annotated, caCertificatePath: "ca.pem")
        #expect(bundle == annotated)
    }

    @Test("A DER file, a key or an empty file is refused with the path, before httpfs reports it vaguely")
    func nonPEMIsRefused() {
        let der = Data([0x30, 0x82, 0x03, 0x1D, 0x30, 0x82, 0x02, 0x05, 0xA0, 0x03, 0x02, 0x01, 0x02])
        let key = Data("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".utf8)
        for file in [der, key, Data()] {
            #expect(throws: QuackConnectError.caCertificateNotPEM(path: "/Users/me/ca.der")) {
                try QuackTrustBundle.combined(defaultBundle: systemBundle, caCertificate: file, caCertificatePath: "/Users/me/ca.der")
            }
        }
    }

    @Test("The not-PEM message names the field and the conversion")
    func notPEMMessage() {
        let message = QuackConnectError.caCertificateNotPEM(path: "/Users/me/ca.der").localizedDescription
        #expect(message.contains("CA Certificate"))
        #expect(message.contains("/Users/me/ca.der"))
        #expect(message.contains("openssl x509 -inform der"))
    }

    @Test("The default bundle is searched in httpfs's order, ending at the one macOS has")
    func defaultLocationsFollowHTTPFS() {
        #expect(QuackTrustBundle.defaultBundleLocations == [
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/ssl/cert.pem"
        ])
    }
}
