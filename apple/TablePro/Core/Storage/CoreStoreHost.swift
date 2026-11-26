//
//  CoreStoreHost.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The core that holds this Mac's stores under `TablePro/Core` in Application Support, opened once per app. The sync
// engine runs on it, so its state files sit under that folder (core ADR 0054, The state file). The account's core
// keeps no files, so sync never opens there. A store that moves into the core opens on this one too, never on a core
// of its own over the same folder.
nonisolated final class CoreStoreHost: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CoreStoreHost")

    static let shared = CoreStoreHost(
        directory: AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("Core", isDirectory: true),
        makeSecrets: { KeychainHostSecrets(keychain: AccountKeychain(keychain: AppStorageEnvironment.shared.deviceOnlyKeychain)) }
    )

    let directory: URL
    private let makeSecrets: @Sendable () -> any HostSecrets
    private let clientVersion: String
    private let opened = OSAllocatedUnfairLock<Core?>(initialState: nil)

    init(
        directory: URL,
        makeSecrets: @escaping @Sendable () -> any HostSecrets,
        clientVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    ) {
        self.directory = directory
        self.makeSecrets = makeSecrets
        self.clientVersion = clientVersion
    }

    // A failed open is tried again by the next caller.
    func core() throws -> Core {
        try opened.withLock { opened in
            if let opened { return opened }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let core = try Core(
                    config: HostConfig(clientVersion: clientVersion, storageDir: directory.path),
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
