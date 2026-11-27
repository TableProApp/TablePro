import Foundation
import os
import TableProFFI

// The one core over the iOS stores in `TableProMobile/Core`, opened on first use. The library and the saved queries live
// in it and the sync engine runs on it, so the engine's state files sit under that folder (core ADR 0054, The state
// file). The account's core keeps no files, so sync never opens there. Query history is readable only while the device
// is unlocked, so its folder takes complete protection before anything opens it; the saved queries keep the app's own
// class, readable after the first unlock.
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
                try Self.protectHistory(URL(fileURLWithPath: core.storeFiles().historyFolder))
                opened = core
                return core
            } catch {
                Self.logger.error("The core over the iOS stores did not open: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }

    // A folder's class is the one new files in it take, so a folder made before this ran is given it too.
    private static func protectHistory(_ folder: URL) throws {
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: protection)
        try FileManager.default.setAttributes(protection, ofItemAtPath: folder.path)
    }
}
