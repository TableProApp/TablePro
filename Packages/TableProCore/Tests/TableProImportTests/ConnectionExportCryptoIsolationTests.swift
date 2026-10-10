@testable import TableProImport
import XCTest

@MainActor
final class ConnectionExportCryptoIsolationTests: XCTestCase {
    private let passphrase = "correct horse battery"

    func testEncryptingLeavesTheMainActorFree() async throws {
        let payload = Data("payload".utf8)
        let passphrase = passphrase
        try await assertLeavesMainActorFree {
            _ = try await ConnectionExportCrypto.encrypt(data: payload, passphrase: passphrase)
        }
    }

    func testDecryptingLeavesTheMainActorFree() async throws {
        let passphrase = passphrase
        let sealed = try await ConnectionExportCrypto.encrypt(data: Data("payload".utf8), passphrase: passphrase)
        try await assertLeavesMainActorFree {
            _ = try await ConnectionExportCrypto.decrypt(data: sealed, passphrase: passphrase)
        }
    }

    func testEncodingAnEncryptedFileLeavesTheMainActorFree() async throws {
        let passphrase = passphrase
        let bundle = try makeBundle()
        try await assertLeavesMainActorFree {
            _ = try await ConnectionBundleCodec.encode(bundle, passphrase: passphrase)
        }
    }

    func testDecodingAnEncryptedFileLeavesTheMainActorFree() async throws {
        let passphrase = passphrase
        let sealed = try await ConnectionBundleCodec.encode(makeBundle(), passphrase: passphrase)
        try await assertLeavesMainActorFree {
            _ = try await ConnectionBundleCodec.decode(sealed, passphrase: passphrase)
        }
    }

    private func makeBundle() throws -> ConnectionBundle {
        try ConnectionBundle(
            appVersion: "1.0",
            connections: [BundleConnection(
                ref: "c1",
                settings: ExportableConnection(
                    name: "Local", host: "127.0.0.1", port: 3_306, database: "test", username: "root", type: "MySQL"
                )
            )]
        )
    }

    private func assertLeavesMainActorFree(
        _ work: @escaping @MainActor () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let probe = DerivationProbe()
        let task = Task { @MainActor in
            probe.hasStarted = true
            try await work()
            probe.hasFinished = true
        }
        while !probe.hasStarted {
            await Task.yield()
        }
        XCTAssertFalse(probe.hasFinished, "The derivation held the main actor until it finished", file: file, line: line)
        try await task.value
        XCTAssertTrue(probe.hasFinished, file: file, line: line)
    }
}

@MainActor
private final class DerivationProbe {
    var hasStarted = false
    var hasFinished = false
}
