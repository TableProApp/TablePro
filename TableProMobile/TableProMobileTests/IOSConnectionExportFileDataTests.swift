import Foundation
import TableProImport
@testable import TableProMobile
import Testing

@MainActor
@Suite("Connection export file data")
struct IOSConnectionExportFileDataTests {
    private func makeEnvelope(password: String?) -> ConnectionExportEnvelope {
        let connection = ExportableConnection(
            name: "Prod", host: "db.example.com", port: 5_432, database: "app", username: "admin",
            type: "PostgreSQL", sshConfig: nil, sslConfig: nil, color: nil, tagName: nil, groupName: nil,
            sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil, additionalFields: nil,
            redisDatabase: nil, startupCommands: nil, localOnly: nil
        )
        let credentials = password.map { password in
            [
                "0": ExportableCredentials(
                    password: password, sshPassword: nil, keyPassphrase: nil,
                    sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
                )
            ]
        }
        return ConnectionExportEnvelope(
            formatVersion: 1, exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
            connections: [connection], groups: nil, tags: nil, credentials: credentials
        )
    }

    @Test("A file without passwords and without a passphrase is plain JSON")
    func plainFileWithoutCredentials() async throws {
        let data = try await IOSConnectionExportService.fileData(for: makeEnvelope(password: nil), passphrase: nil)

        #expect(!ConnectionExportCrypto.isEncrypted(data))
        let decoded = try ConnectionImportDecoder.decodeData(data)
        #expect(decoded.connections.map(\.name) == ["Prod"])
        #expect(decoded.credentials == nil)
    }

    @Test("Passwords are never written without a passphrase", arguments: [nil, ""] as [String?])
    func credentialsNeedPassphrase(passphrase: String?) async {
        await #expect(throws: IOSConnectionExportService.ExportError.credentialsNeedPassphrase) {
            try await IOSConnectionExportService.fileData(for: makeEnvelope(password: "s3cret"), passphrase: passphrase)
        }
    }

    @Test("A passphrase seals the file and the same passphrase opens it with its passwords")
    func sealedFileRoundTrips() async throws {
        let data = try await IOSConnectionExportService.fileData(
            for: makeEnvelope(password: "s3cret"),
            passphrase: "correct horse"
        )

        #expect(ConnectionExportCrypto.isEncrypted(data))
        let decoded = try await ConnectionImportDecoder.decodeEncryptedData(data, passphrase: "correct horse")
        #expect(decoded.credentials?["0"]?.password == "s3cret")
    }

    @Test("A sealed file refuses the wrong passphrase")
    func wrongPassphraseIsRefused() async throws {
        let data = try await IOSConnectionExportService.fileData(
            for: makeEnvelope(password: "s3cret"),
            passphrase: "correct horse"
        )

        await #expect(throws: ConnectionExportError.self) {
            try await ConnectionImportDecoder.decodeEncryptedData(data, passphrase: "wrong horse")
        }
    }

    @Test("Sealing a file with a passphrase leaves the main actor free")
    func sealingLeavesMainActorFree() async throws {
        let envelope = makeEnvelope(password: "s3cret")
        let probe = SealingProbe()
        let task = Task { @MainActor in
            probe.hasStarted = true
            _ = try await IOSConnectionExportService.fileData(for: envelope, passphrase: "correct horse")
            probe.hasFinished = true
        }
        while !probe.hasStarted {
            await Task.yield()
        }

        #expect(!probe.hasFinished)
        try await task.value
        #expect(probe.hasFinished)
    }
}

@MainActor
private final class SealingProbe {
    var hasStarted = false
    var hasFinished = false
}
