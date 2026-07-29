import XCTest
@testable import TableProImport

final class ConnectionExportCryptoTests: XCTestCase {
    func testEncryptDecryptRoundTripRecoversOriginal() throws {
        let original = Data("the quick brown fox".utf8)
        let encrypted = try ConnectionExportCrypto.encrypt(data: original, passphrase: "correct horse battery")
        let decrypted = try ConnectionExportCrypto.decrypt(data: encrypted, passphrase: "correct horse battery")
        XCTAssertEqual(decrypted, original)
    }

    func testEncryptedBlobIsDetectedAndPlainJSONIsNot() throws {
        let encrypted = try ConnectionExportCrypto.encrypt(data: Data("x".utf8), passphrase: "pw")
        XCTAssertTrue(ConnectionExportCrypto.isEncrypted(encrypted))
        XCTAssertFalse(ConnectionExportCrypto.isEncrypted(Data("{\"a\":1}".utf8)))
    }

    func testWrongPassphraseThrowsInvalidPassphrase() throws {
        let encrypted = try ConnectionExportCrypto.encrypt(data: Data("secret".utf8), passphrase: "right")
        XCTAssertThrowsError(try ConnectionExportCrypto.decrypt(data: encrypted, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? ConnectionExportCryptoError, .invalidPassphrase)
        }
    }

    func testTruncatedHeaderThrowsCorruptData() {
        let tooShort = Data([0x54, 0x50, 0x52, 0x4F, 0x01])
        XCTAssertThrowsError(try ConnectionExportCrypto.decrypt(data: tooShort, passphrase: "pw")) { error in
            XCTAssertEqual(error as? ConnectionExportCryptoError, .corruptData)
        }
    }

    func testNonMagicPrefixThrowsCorruptData() throws {
        var blob = try ConnectionExportCrypto.encrypt(data: Data("hello world data".utf8), passphrase: "pw")
        blob[0] = 0x00
        XCTAssertThrowsError(try ConnectionExportCrypto.decrypt(data: blob, passphrase: "pw")) { error in
            XCTAssertEqual(error as? ConnectionExportCryptoError, .corruptData)
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
