import Foundation
import TableProImport
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection export file data")
struct IOSConnectionExportFileDataTests {
    private let fixture: AppStateFixture
    private let store = MockSecureStore()
    private let appState: AppState

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, secureStore: store)
        let connection = DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "admin",
            database: "app"
        )
        #expect(appState.addConnection(connection))
        store.seed(ConnectionSecretKind.password.account(for: connection.id), "s3cret")
    }

    private func export(includeCredentials: Bool, passphrase: String?) async throws -> Data {
        try await IOSConnectionExportService.exportData(
            connections: appState.connections,
            appState: appState,
            includeCredentials: includeCredentials,
            passphrase: passphrase
        )
    }

    @Test("A file without passwords and without a passphrase is plain JSON")
    func plainFileWithoutCredentials() async throws {
        let data = try await export(includeCredentials: false, passphrase: nil)

        #expect(!ConnectionBundleCodec.isEncrypted(data))
        let decoded = try ConnectionBundleCodec.decode(data)
        #expect(decoded.connections.map(\.settings.name) == ["Prod"])
        #expect(decoded.credentials.isEmpty)
    }

    @Test("Passwords are never written without a passphrase", arguments: [nil, ""] as [String?])
    func credentialsNeedPassphrase(passphrase: String?) async {
        await #expect(throws: ConnectionBundleError.credentialsRequireEncryption) {
            try await export(includeCredentials: true, passphrase: passphrase)
        }
    }

    @Test("A passphrase seals the file and the same passphrase opens it with its passwords")
    func sealedFileRoundTrips() async throws {
        let data = try await export(includeCredentials: true, passphrase: "correct horse")

        #expect(ConnectionBundleCodec.isEncrypted(data))
        let decoded = try await ConnectionBundleCodec.decode(data, passphrase: "correct horse")
        let ref = try #require(decoded.connections.first?.ref)
        #expect(decoded.credentials[ref]?.password == "s3cret")
    }

    @Test("A sealed file refuses the wrong passphrase")
    func wrongPassphraseIsRefused() async throws {
        let data = try await export(includeCredentials: true, passphrase: "correct horse")

        await #expect(throws: ConnectionBundleError.self) {
            try await ConnectionBundleCodec.decode(data, passphrase: "wrong horse")
        }
    }

    @Test("A sealed file opened without its passphrase asks for one")
    func sealedFileNeedsPassphrase() async throws {
        let data = try await export(includeCredentials: true, passphrase: "correct horse")

        #expect(throws: ConnectionBundleError.requiresPassphrase) {
            try ConnectionBundleCodec.decode(data)
        }
    }

    @Test("Sealing a file with a passphrase leaves the main actor free")
    func sealingLeavesMainActorFree() async throws {
        let probe = SealingProbe()
        let state = appState
        let connections = appState.connections
        let (started, signalStarted) = AsyncStream.makeStream(of: Void.self)
        let sealing = Task { @MainActor in
            signalStarted.yield()
            _ = try await IOSConnectionExportService.exportData(
                connections: connections,
                appState: state,
                includeCredentials: true,
                passphrase: "correct horse"
            )
            probe.hasFinished = true
        }
        for await _ in started {
            break
        }

        #expect(!probe.hasFinished)
        try await sealing.value
        #expect(probe.hasFinished)
    }
}

@MainActor
private final class SealingProbe {
    var hasFinished = false
}
