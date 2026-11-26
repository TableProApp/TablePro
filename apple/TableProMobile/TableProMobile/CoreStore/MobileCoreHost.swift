import Foundation
import os
import TableProFFI

// The one core over the iOS stores in `TableProMobile/Core`, opened on first use. The library and the saved queries live
// in it and the sync engine runs on it, so the engine's state files sit under that folder (core ADR 0054, The state
// file). The account's core keeps no files, so sync never opens there.
nonisolated final class MobileCoreHost: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MobileCoreHost")

    let directory: URL
    private let clientVersion: String
    private let makeSecrets: @Sendable () -> any HostSecrets
    private let opened = OSAllocatedUnfairLock<Core?>(initialState: nil)

    init(directory: URL, clientVersion: String, makeSecrets: @escaping @Sendable () -> any HostSecrets) {
        self.directory = directory
        self.clientVersion = clientVersion
        self.makeSecrets = makeSecrets
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
                Self.logger.error("The core over the iOS stores did not open: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }
}
