import Foundation
import os
import Security

nonisolated enum CertificateRole: String, CaseIterable, Identifiable, Sendable {
    case certificateAuthority
    case clientCertificate
    case clientKey

    var id: String { rawValue }
}

nonisolated enum CertificateStoreError: Error, LocalizedError {
    case writeFailed(OSStatus)

    var errorDescription: String? {
        String(localized: "The certificate could not be saved to this device's keychain.")
    }
}

nonisolated protocol CertificateMaterialStoring: Sendable {
    func store(_ pem: String, role: CertificateRole, for connectionId: UUID) throws
    func pem(role: CertificateRole, for connectionId: UUID) -> String?
    func delete(role: CertificateRole, for connectionId: UUID)
    func deleteAll(for connectionId: UUID)
}

nonisolated final class CertificateMaterialStore: CertificateMaterialStoring {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CertificateMaterialStore")
    private let serviceName = "com.TablePro.clientCertificates"
    private let items: any KeychainItemStore

    init(items: any KeychainItemStore = SystemKeychainItemStore()) {
        self.items = items
    }

    private func account(_ role: CertificateRole, _ connectionId: UUID) -> String {
        "\(connectionId.uuidString).\(role.rawValue)"
    }

    private func baseQuery(_ role: CertificateRole, _ connectionId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account(role, connectionId),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    // Updated in place: a delete then a failed add would lose the certificate the connection already uses.
    func store(_ pem: String, role: CertificateRole, for connectionId: UUID) throws {
        guard let data = pem.data(using: .utf8) else { return }

        let target = baseQuery(role, connectionId)
        let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = items.update(target, attributes: [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ])
        if status == errSecItemNotFound {
            var attributes = target
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = accessible
            status = items.add(attributes)
        }
        guard status == errSecSuccess else {
            Self.logger.error("Storing \(role.rawValue, privacy: .public) failed with \(status)")
            throw CertificateStoreError.writeFailed(status)
        }
    }

    func pem(role: CertificateRole, for connectionId: UUID) -> String? {
        let found = items.copyItem(baseQuery(role, connectionId))
        guard found.status == errSecSuccess, let data = found.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(role: CertificateRole, for connectionId: UUID) {
        _ = items.delete(baseQuery(role, connectionId))
    }

    func deleteAll(for connectionId: UUID) {
        for role in CertificateRole.allCases {
            delete(role: role, for: connectionId)
        }
    }
}
