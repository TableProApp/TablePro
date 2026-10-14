import Foundation
@testable import TableProImport
import Testing

struct ConnectionExportCryptoTests {
    @Test func testEncryptDecryptRoundTripRecoversOriginal() async throws {
        let original = Data("the quick brown fox".utf8)
        let encrypted = try await ConnectionExportCrypto.encrypt(data: original, passphrase: "correct horse battery")
        let decrypted = try await ConnectionExportCrypto.decrypt(data: encrypted, passphrase: "correct horse battery")
        #expect(decrypted == original)
    }

    @Test func testEncryptedBlobIsDetectedAndPlainJSONIsNot() async throws {
        let encrypted = try await ConnectionExportCrypto.encrypt(data: Data("x".utf8), passphrase: "pw")
        #expect(ConnectionExportCrypto.isEncrypted(encrypted))
        #expect(!(ConnectionExportCrypto.isEncrypted(Data("{\"a\":1}".utf8))))
    }

    @Test func testWrongPassphraseThrowsInvalidPassphrase() async throws {
        let encrypted = try await ConnectionExportCrypto.encrypt(data: Data("secret".utf8), passphrase: "right")
        await assertDecryptFails(encrypted, passphrase: "wrong", with: .invalidPassphrase)
    }

    @Test func testTruncatedHeaderThrowsCorruptData() async {
        let tooShort = Data([0x54, 0x50, 0x52, 0x4F, 0x01])
        await assertDecryptFails(tooShort, passphrase: "pw", with: .corruptData)
    }

    @Test func testNonMagicPrefixThrowsCorruptData() async throws {
        var blob = try await ConnectionExportCrypto.encrypt(data: Data("hello world data".utf8), passphrase: "pw")
        blob[0] = 0x00
        await assertDecryptFails(blob, passphrase: "pw", with: .corruptData)
    }

    private func assertDecryptFails(
        _ data: Data,
        passphrase: String,
        with expected: ConnectionExportCryptoError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await ConnectionExportCrypto.decrypt(data: data, passphrase: passphrase)
            Issue.record("Decrypting was expected to throw \(expected)", sourceLocation: sourceLocation)
        } catch {
            #expect(error as? ConnectionExportCryptoError == expected, sourceLocation: sourceLocation)
        }
    }
}

extension ConnectionExportCryptoError: Equatable {
    public static func == (lhs: ConnectionExportCryptoError, rhs: ConnectionExportCryptoError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidPassphrase, .invalidPassphrase), (.corruptData, .corruptData):
            return true
        case let (.unsupportedVersion(a), .unsupportedVersion(b)):
            return a == b
        default:
            return false
        }
    }
}
