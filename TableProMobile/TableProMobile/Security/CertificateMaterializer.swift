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

    init(store: any CertificateMaterialStoring = CertificateMaterialStore(), fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func materialize(for connectionId: UUID) throws -> MaterializedCertificates {
        let paths = try CertificateRole.allCases.reduce(into: [CertificateRole: String]()) { result, role in
            guard let pem = store.pem(role: role, for: connectionId) else { return }
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
        try? fileManager.removeItem(at: directory)
    }

    func sweep() {
        guard let root = try? rootDirectory(), fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
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
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent(Self.directoryName, isDirectory: true)
    }
}
