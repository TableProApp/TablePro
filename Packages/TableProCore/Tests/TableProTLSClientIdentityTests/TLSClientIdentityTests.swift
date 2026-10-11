import Foundation
import Security
import TableProTLSClientIdentity
import TableProTLSTestFixtures
import Testing

struct IdentityCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let certificate: Data
    let privateKey: Data
    let commonName: String

    static let all: [IdentityCase] = [
        IdentityCase(
            testDescription: "RSA PKCS#8 PEM",
            certificate: TLSTestFixtures.data(TLSTestFixtures.clientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS8),
            commonName: "probe-client"
        ),
        IdentityCase(
            testDescription: "RSA PKCS#1 PEM",
            certificate: TLSTestFixtures.data(TLSTestFixtures.clientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS1),
            commonName: "probe-client"
        ),
        IdentityCase(
            testDescription: "DER certificate with a DER PKCS#8 RSA key",
            certificate: TLSTestFixtures.der(TLSTestFixtures.clientCertificate),
            privateKey: TLSTestFixtures.der(TLSTestFixtures.clientKeyPKCS8),
            commonName: "probe-client"
        ),
        IdentityCase(
            testDescription: "DER certificate with a DER PKCS#1 RSA key",
            certificate: TLSTestFixtures.der(TLSTestFixtures.clientCertificate),
            privateKey: TLSTestFixtures.der(TLSTestFixtures.clientKeyPKCS1),
            commonName: "probe-client"
        ),
        IdentityCase(
            testDescription: "EC P-256 SEC1 PEM",
            certificate: TLSTestFixtures.data(TLSTestFixtures.ecClientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.ecKeySEC1),
            commonName: "probe-ec-client"
        ),
        IdentityCase(
            testDescription: "EC P-256 PKCS#8 PEM",
            certificate: TLSTestFixtures.data(TLSTestFixtures.ecClientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.ecKeyPKCS8),
            commonName: "probe-ec-client"
        ),
        IdentityCase(
            testDescription: "EC P-256 SEC1 DER",
            certificate: TLSTestFixtures.der(TLSTestFixtures.ecClientCertificate),
            privateKey: TLSTestFixtures.der(TLSTestFixtures.ecKeySEC1),
            commonName: "probe-ec-client"
        ),
        IdentityCase(
            testDescription: "EC P-256 PKCS#8 DER",
            certificate: TLSTestFixtures.der(TLSTestFixtures.ecClientCertificate),
            privateKey: TLSTestFixtures.der(TLSTestFixtures.ecKeyPKCS8),
            commonName: "probe-ec-client"
        ),
        IdentityCase(
            testDescription: "EC P-384 SEC1 PEM",
            certificate: TLSTestFixtures.data(TLSTestFixtures.p384ClientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.p384KeySEC1),
            commonName: "probe-p384-client"
        )
    ]
}

struct TLSClientIdentityTests {
    @Test("Every supported certificate and key form gives an identity whose key signs for its certificate", arguments: IdentityCase.all)
    func supportedForms(_ testCase: IdentityCase) throws {
        let credential = try TLSClientIdentity.credential(certificate: testCase.certificate, privateKey: testCase.privateKey)

        let identity = try #require(credential.identity)
        let leaf = try certificate(of: identity)
        #expect(commonName(of: leaf) == testCase.commonName)
        #expect(try signatureVerifies(identity: identity, leaf: leaf))
        #expect(credential.certificates.isEmpty)
    }

    @Test("A chain listed CA first still picks the client leaf by its key and keeps only the CA as the chain")
    func chainOrderDoesNotMatter() throws {
        for certificate in [
            TLSTestFixtures.data(TLSTestFixtures.caCertificate, TLSTestFixtures.clientCertificate),
            TLSTestFixtures.data(TLSTestFixtures.clientCertificate, TLSTestFixtures.caCertificate)
        ] {
            let credential = try TLSClientIdentity.credential(
                certificate: certificate,
                privateKey: TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS8)
            )

            let identity = try #require(credential.identity)
            #expect(commonName(of: try self.certificate(of: identity)) == "probe-client")
            let chain = credential.certificates.compactMap { item -> String? in
                guard CFGetTypeID(item as CFTypeRef) == SecCertificateGetTypeID() else { return nil }
                return commonName(of: unsafeDowncast(item as AnyObject, to: SecCertificate.self))
            }
            #expect(chain == ["TablePro Test CA"])
        }
    }

    @Test("One file holding the certificate and the key serves as both")
    func combinedFile() throws {
        let combined = TLSTestFixtures.data(TLSTestFixtures.clientCertificate, TLSTestFixtures.clientKeyPKCS8)

        let credential = try TLSClientIdentity.credential(certificate: combined, privateKey: combined)

        #expect(commonName(of: try certificate(of: try #require(credential.identity))) == "probe-client")
    }

    @Test("An encrypted PEM key is refused as encrypted, whichever scheme encrypted it")
    func encryptedKeys() {
        for key in [
            TLSTestFixtures.data(TLSTestFixtures.encryptedKeyPBES2),
            TLSTestFixtures.data(TLSTestFixtures.encryptedKeyLegacy),
            TLSTestFixtures.data(TLSTestFixtures.encryptedKey3DES)
        ] {
            #expect(throws: TLSClientIdentityError.keyEncrypted) {
                try TLSClientIdentity.credential(
                    certificate: TLSTestFixtures.data(TLSTestFixtures.clientCertificate),
                    privateKey: key
                )
            }
        }
    }

    @Test("A key that belongs to another certificate is refused")
    func mismatchedKey() {
        #expect(throws: TLSClientIdentityError.keyDoesNotMatchCertificate) {
            try TLSClientIdentity.credential(
                certificate: TLSTestFixtures.data(TLSTestFixtures.clientCertificate),
                privateKey: TLSTestFixtures.data(TLSTestFixtures.rogueKey)
            )
        }
    }

    @Test("A key file given as the certificate is refused as an unreadable certificate")
    func keyAsCertificate() {
        #expect(throws: TLSClientIdentityError.certificateUnreadable) {
            try TLSClientIdentity.credential(
                certificate: TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS8),
                privateKey: TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS8)
            )
        }
    }

    @Test("Empty or garbage key data is refused as an unreadable key")
    func unreadableKeys() {
        for key in [Data(), Data("not a key".utf8), TLSTestFixtures.data(TLSTestFixtures.caCertificate)] {
            #expect(throws: TLSClientIdentityError.keyUnreadable) {
                try TLSClientIdentity.credential(
                    certificate: TLSTestFixtures.data(TLSTestFixtures.clientCertificate),
                    privateKey: key
                )
            }
        }
    }

    @Test("Files that cannot be read are named as such, certificate first")
    func unreadableFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificateFile = directory.appendingPathComponent("client.pem")
        let keyFile = directory.appendingPathComponent("client.key")
        let missing = directory.appendingPathComponent("missing")
        try TLSTestFixtures.data(TLSTestFixtures.clientCertificate).write(to: certificateFile)
        try TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS1).write(to: keyFile)

        #expect(throws: TLSClientIdentityError.certificateFileUnreadable) {
            try TLSClientIdentity.credential(certificateFile: missing, privateKeyFile: missing)
        }
        #expect(throws: TLSClientIdentityError.keyFileUnreadable) {
            try TLSClientIdentity.credential(certificateFile: certificateFile, privateKeyFile: missing)
        }
        let credential = try TLSClientIdentity.credential(certificateFile: certificateFile, privateKeyFile: keyFile)
        #expect(commonName(of: try certificate(of: try #require(credential.identity))) == "probe-client")
    }

    private func certificate(of identity: SecIdentity) throws -> SecCertificate {
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        return try #require(certificate)
    }

    private func commonName(of certificate: SecCertificate) -> String? {
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        return name as String?
    }

    private func signatureVerifies(identity: SecIdentity, leaf: SecCertificate) throws -> Bool {
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess)
        let key = try #require(privateKey)
        let publicKey = try #require(SecCertificateCopyKey(leaf))
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        let isElliptic = (attributes?[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String)
        let algorithm: SecKeyAlgorithm = isElliptic ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        let message = Data("TablePro client identity".utf8) as CFData
        let signature = try #require(SecKeyCreateSignature(key, algorithm, message, nil))
        return SecKeyVerifySignature(publicKey, algorithm, message, signature, nil)
    }
}
