import Foundation
@testable import TableProMobile
import Testing

@Suite("PEM document")
struct PEMDocumentTests {
    private let der = Data((0..<200).map { UInt8($0 % 251) })

    @Test("encoding wraps base64 at 64 characters between the right markers")
    func encodeWrapsAndMarks() {
        let pem = PEMDocument.encode(der, as: .certificate)
        let lines = pem.split(separator: "\n").map(String.init)

        #expect(lines.first == "-----BEGIN CERTIFICATE-----")
        #expect(lines.last == "-----END CERTIFICATE-----")

        let body = lines.dropFirst().dropLast()
        #expect(body.allSatisfy { $0.count <= PEMDocument.lineLength })
        #expect(body.dropLast().allSatisfy { $0.count == PEMDocument.lineLength })
        #expect(Data(base64Encoded: body.joined()) == der)
    }

    @Test("an encoded block round-trips through the parser")
    func roundTrip() {
        let pem = PEMDocument.encode(der, as: .pkcs8PrivateKey)
        let blocks = PEMDocument.blocks(in: pem)

        #expect(blocks.count == 1)
        #expect(blocks.first?.label == .pkcs8PrivateKey)
        #expect(blocks.first?.text == pem.trimmingCharacters(in: .newlines))
    }

    @Test("a bundle carrying a certificate and a key is split into both")
    func splitsBundle() {
        let bundle = PEMDocument.encode(der, as: .certificate) + PEMDocument.encode(der, as: .pkcs8PrivateKey)
        let inspection = PEMDocument.inspect(bundle)

        #expect(inspection.certificates.count == 1)
        #expect(inspection.privateKeys.count == 1)
        #expect(!inspection.usesPassphrase)
        #expect(!inspection.isEmpty)
    }

    @Test("a chain of certificates keeps every block in order")
    func keepsWholeChain() {
        let leaf = PEMDocument.encode(Data([1, 2, 3]), as: .certificate)
        let intermediate = PEMDocument.encode(Data([4, 5, 6]), as: .certificate)
        let inspection = PEMDocument.inspect(leaf + intermediate)

        #expect(inspection.certificates.count == 2)
        #expect(inspection.certificates[0].text.contains("AQID"))
        #expect(inspection.certificates[1].text.contains("BAUG"))
    }

    @Test("surrounding bag attributes and preamble are ignored")
    func ignoresPreamble() {
        let noisy = """
        Bag Attributes
            friendlyName: client
            localKeyID: 01 02 03
        subject=/CN=client
        issuer=/CN=Test CA

        \(PEMDocument.encode(der, as: .certificate))
        trailing junk
        """
        let inspection = PEMDocument.inspect(noisy)

        #expect(inspection.certificates.count == 1)
        #expect(inspection.privateKeys.isEmpty)
    }

    @Test("a PKCS#8 encrypted key is reported as needing a passphrase")
    func detectsEncryptedPKCS8() {
        let inspection = PEMDocument.inspect(PEMDocument.encode(der, as: .encryptedPrivateKey))

        #expect(inspection.usesPassphrase)
        #expect(inspection.privateKeys.count == 1)
    }

    @Test("a legacy encrypted key is detected by its Proc-Type header")
    func detectsLegacyEncryptionHeader() {
        let legacy = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,0123456789ABCDEF

        \(der.base64EncodedString())
        -----END RSA PRIVATE KEY-----
        """
        let inspection = PEMDocument.inspect(legacy)

        #expect(inspection.usesPassphrase)
        #expect(inspection.privateKeys.count == 1)
    }

    @Test("an unterminated block is not returned")
    func ignoresUnterminatedBlock() {
        let truncated = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString())\n"

        #expect(PEMDocument.blocks(in: truncated).isEmpty)
        #expect(PEMDocument.inspect(truncated).isEmpty)
    }

    @Test("text carrying no PEM block inspects as empty")
    func emptyInput() {
        #expect(PEMDocument.inspect("").isEmpty)
        #expect(PEMDocument.inspect("not a certificate").isEmpty)
    }
}
