import Foundation
import os

nonisolated struct MaterializedCertificates: Equatable, Sendable {
    let caCertificatePath: String?
    let clientCertificatePath: String?
    let clientKeyPath: String?

    var isEmpty: Bool {
        caCertificatePath == nil && clientCertificatePath == nil && clientKeyPath == nil
    }
}

nonisolated final class CertificateMaterializer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CertificateMaterializer")
    private static let directoryName = "ClientCertificates"

    private let store: any CertificateMaterialStoring
    private let fileManager: FileManager
    private let root: URL?

    // `root` is the folder that holds one folder per connection; nil is Application Support's.
    init(
        store: any CertificateMaterialStoring = CertificateMaterialStore(),
        fileManager: FileManager = .default,
        root: URL? = nil
    ) {
        self.store = store
        self.fileManager = fileManager
        self.root = root
    }

    // A role the store no longer holds loses its file, so a certificate removed in the form leaves no key behind.
    func materialize(for connectionId: UUID) throws -> MaterializedCertificates {
        let paths = try CertificateRole.allCases.reduce(into: [CertificateRole: String]()) { result, role in
            guard let pem = store.pem(role: role, for: connectionId) else {
                release(role, for: connectionId)
                return
            }
            result[role] = try write(pem, role: role, for: connectionId)
        }

        return MaterializedCertificates(
            caCertificatePath: paths[.certificateAuthority],
            clientCertificatePath: paths[.clientCertificate],
            clientKeyPath: paths[.clientKey]
        )
    }

    func release(for connectionId: UUID) {
        let directory = directory(for: connectionId)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            Self.logger.error("Client certificate files were not removed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // Deletes before this release left the files of connections that are gone. Only a loaded library may ask.
    func releaseAll(except kept: Set<UUID>) {
        guard let root = try? rootDirectory(),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            guard let connectionId = UUID(uuidString: name), !kept.contains(connectionId) else { continue }
            release(for: connectionId)
        }
    }

    func release(_ role: CertificateRole, for connectionId: UUID) {
        let file = directory(for: connectionId).appendingPathComponent("\(role.rawValue).pem")
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            try fileManager.removeItem(at: file)
        } catch {
            Self.logger.error("A stale client certificate file was not removed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func write(_ pem: String, role: CertificateRole, for connectionId: UUID) throws -> String {
        let directory = directory(for: connectionId)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let file = directory.appendingPathComponent("\(role.rawValue).pem")
        try pem.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try (file as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )

        var excluded = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        return file.path
    }

    private func directory(for connectionId: UUID) -> URL {
        let root = (try? rootDirectory()) ?? fileManager.temporaryDirectory
        return root.appendingPathComponent(connectionId.uuidString, isDirectory: true)
    }

    private func rootDirectory() throws -> URL {
        if let root { return root }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent(Self.directoryName, isDirectory: true)
    }
}
