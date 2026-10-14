import Foundation
@testable import TableProImport
import Testing

@MainActor
struct ConnectionExportCryptoIsolationTests {
    private let passphrase = "correct horse battery"

    @Test func testEncryptingLeavesTheMainActorFree() async throws {
        let payload = Data("payload".utf8)
        let passphrase = passphrase
        try await assertLeavesMainActorFree {
            _ = try await ConnectionExportCrypto.encrypt(data: payload, passphrase: passphrase)
        }
    }

    @Test func testDecryptingLeavesTheMainActorFree() async throws {
        let passphrase = passphrase
        let sealed = try await ConnectionExportCrypto.encrypt(data: Data("payload".utf8), passphrase: passphrase)
        try await assertLeavesMainActorFree {
            _ = try await ConnectionExportCrypto.decrypt(data: sealed, passphrase: passphrase)
        }
    }

    @Test func testEncodingAnEncryptedFileLeavesTheMainActorFree() async throws {
        let passphrase = passphrase
        let bundle = try makeBundle()
        try await assertLeavesMainActorFree {
            _ = try await ConnectionBundleCodec.encode(bundle, passphrase: passphrase)
        }
    }

    @Test func testDecodingAnEncryptedFileLeavesTheMainActorFree() async throws {
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
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let probe = DerivationProbe()
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            signalStart.yield()
            signalStart.finish()
            try await work()
            probe.hasFinished = true
        }
        // This resumes on the main actor, so it runs before the work finishes only if the work let go of it.
        for await _ in started { break }
        #expect(!probe.hasFinished, "The derivation held the main actor until it finished", sourceLocation: sourceLocation)
        try await task.value
        #expect(probe.hasFinished, sourceLocation: sourceLocation)
    }
}

@MainActor
private final class DerivationProbe {
    var hasFinished = false
}
