//
//  CoreStoreHost.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The one core over `TablePro/Core` in Application Support. Every store the Mac keeps in the core and the sync engine
// open on it, so no two runtimes ever hold the same files: the library's `connections.json`, `history.db` and the sync
// state files under its state folder (core ADR 0054, The state file; 0060). Opened on first use; a failed open is tried
// again by the next caller. The account's core keeps no files and stays apart.
nonisolated final class CoreStoreHost: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CoreStoreHost")

    static let shared = CoreStoreHost(
        folder: AppStorageEnvironment.shared.supportDirectory.appendingPathComponent("Core", isDirectory: true),
        makeSecrets: {
            CoreStoreSecrets(
                items: KeychainHostSecrets(keychain: AccountKeychain(keychain: AppStorageEnvironment.shared.deviceOnlyKeychain)),
                connections: ConnectionKeychainSecrets(keychain: AppStorageEnvironment.shared.keychain) { id in
                    LocalOnlyConnections.shared.contains(id)
                }
            )
        }
    )

    let folder: URL
    private let makeSecrets: @Sendable () -> any HostSecrets
    private let clientVersion: String
    private let opened = OSAllocatedUnfairLock<Core?>(initialState: nil)

    init(
        folder: URL,
        makeSecrets: @escaping @Sendable () -> any HostSecrets,
        clientVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    ) {
        self.folder = folder
        self.makeSecrets = makeSecrets
        self.clientVersion = clientVersion
    }

    func core() throws -> Core {
        try opened.withLock { opened in
            if let opened { return opened }
            do {
                // Private, since history.db holds the SQL a person ran.
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let core = try Core(
                    config: HostConfig(clientVersion: clientVersion, storageDir: folder.path),
                    secrets: makeSecrets()
                )
                opened = core
                return core
            } catch {
                Self.logger.error("The core over the Mac's stores did not open: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }
}
