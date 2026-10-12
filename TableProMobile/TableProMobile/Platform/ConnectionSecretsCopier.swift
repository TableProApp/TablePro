import Foundation
import os
import TableProDatabase

nonisolated struct ConnectionSecrets: Sendable {
    static let secureStoreKeyPrefixes = ConnectionSecretKind.allCases.map(\.prefix)

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionSecrets")

    let secureStore: any SecureStore
    let certificateStore: any CertificateMaterialStoring
    let bookmarkStore: FileBookmarkStore

    init(
        secureStore: any SecureStore,
        certificateStore: any CertificateMaterialStoring = CertificateMaterialStore(),
        bookmarkStore: FileBookmarkStore = FileBookmarkStore()
    ) {
        self.secureStore = secureStore
        self.certificateStore = certificateStore
        self.bookmarkStore = bookmarkStore
    }

    @discardableResult
    func copy(from sourceId: UUID, to targetId: UUID) -> Bool {
        var copiedEverything = true
        for prefix in Self.secureStoreKeyPrefixes {
            do {
                guard let value = try secureStore.retrieve(forKey: prefix + sourceId.uuidString),
                      !value.isEmpty else { continue }
                try secureStore.store(value, forKey: prefix + targetId.uuidString)
            } catch {
                Self.logger.error("Copying \(prefix, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                copiedEverything = false
            }
        }
        for role in CertificateRole.allCases {
            guard let pem = certificateStore.pem(role: role, for: sourceId) else { continue }
            do {
                try certificateStore.store(pem, role: role, for: targetId)
            } catch {
                Self.logger.error("Copying \(role.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                copiedEverything = false
            }
        }
        if let bookmark = bookmarkStore.bookmark(for: sourceId) {
            bookmarkStore.save(bookmark, for: targetId)
        }
        return copiedEverything
    }

    func storeMissingPrivateKeys(_ keys: [UUID: String]) -> [UUID: String] {
        var unstored: [UUID: String] = [:]
        for (connectionId, key) in keys.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let account = ConnectionSecretKind.sshPrivateKey.account(for: connectionId)
            do {
                if let existing = try secureStore.retrieve(forKey: account), !existing.isEmpty {
                    continue
                }
                try secureStore.store(key, forKey: account)
            } catch {
                Self.logger.error(
                    "Storing the pasted SSH key of \(connectionId.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                unstored[connectionId] = key
            }
        }
        return unstored
    }

    func delete(for connectionId: UUID) {
        for prefix in Self.secureStoreKeyPrefixes {
            try? secureStore.delete(forKey: prefix + connectionId.uuidString)
        }
        certificateStore.deleteAll(for: connectionId)
        bookmarkStore.delete(for: connectionId)
    }
}
