@testable import TableProImport
import XCTest

final class ConnectionExportCryptoTests: XCTestCase {
    func testEncryptDecryptRoundTripRecoversOriginal() async throws {
        let original = Data("the quick brown fox".utf8)
        let encrypted = try await ConnectionExportCrypto.encrypt(data: original, passphrase: "correct horse battery")
        let decrypted = try await ConnectionExportCrypto.decrypt(data: encrypted, passphrase: "correct horse battery")
        XCTAssertEqual(decrypted, original)
    }

    func testEncryptedBlobIsDetectedAndPlainJSONIsNot() async throws {
        let encrypted = try await ConnectionExportCrypto.encrypt(data: Data("x".utf8), passphrase: "pw")
        XCTAssertTrue(ConnectionExportCrypto.isEncrypted(encrypted))
        XCTAssertFalse(ConnectionExportCrypto.isEncrypted(Data("{\"a\":1}".utf8)))
    }

    func testWrongPassphraseThrowsInvalidPassphrase() async throws {
        let encrypted = try await ConnectionExportCrypto.encrypt(data: Data("secret".utf8), passphrase: "right")
        await assertDecryptFails(encrypted, passphrase: "wrong", with: .invalidPassphrase)
    }

    func testTruncatedHeaderThrowsCorruptData() async {
        let tooShort = Data([0x54, 0x50, 0x52, 0x4F, 0x01])
        await assertDecryptFails(tooShort, passphrase: "pw", with: .corruptData)
    }

    func testNonMagicPrefixThrowsCorruptData() async throws {
        var blob = try await ConnectionExportCrypto.encrypt(data: Data("hello world data".utf8), passphrase: "pw")
        blob[0] = 0x00
        await assertDecryptFails(blob, passphrase: "pw", with: .corruptData)
    }

    private func assertDecryptFails(
        _ data: Data,
        passphrase: String,
        with expected: ConnectionExportCryptoError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ConnectionExportCrypto.decrypt(data: data, passphrase: passphrase)
            XCTFail("Decrypting was expected to throw \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ConnectionExportCryptoError, expected, file: file, line: line)
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
