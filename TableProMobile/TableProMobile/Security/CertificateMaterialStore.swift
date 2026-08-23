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

    private func account(_ role: CertificateRole, _ connectionId: UUID) -> String {
        "\(connectionId.uuidString).\(role.rawValue)"
    }

    private func baseQuery(_ role: CertificateRole, _ connectionId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account(role, connectionId),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func store(_ pem: String, role: CertificateRole, for connectionId: UUID) throws {
        guard let data = pem.data(using: .utf8) else { return }

        SecItemDelete(baseQuery(role, connectionId) as CFDictionary)

        var addQuery = baseQuery(role, connectionId)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.logger.error("Storing \(role.rawValue, privacy: .public) failed with \(status)")
            throw CertificateStoreError.writeFailed(status)
        }
    }

    func pem(role: CertificateRole, for connectionId: UUID) -> String? {
        var query = baseQuery(role, connectionId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(role: CertificateRole, for connectionId: UUID) {
        SecItemDelete(baseQuery(role, connectionId) as CFDictionary)
    }

    func deleteAll(for connectionId: UUID) {
        for role in CertificateRole.allCases {
            delete(role: role, for: connectionId)
        }
    }
}
