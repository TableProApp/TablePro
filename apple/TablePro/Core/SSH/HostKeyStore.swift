import Foundation
import TableProSSHTransport

extension HostKeyStore {
    static let shared: HostKeyStore = {
        let tableProDir = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        try? FileManager.default.createDirectory(at: tableProDir, withIntermediateDirectories: true)
        return HostKeyStore(filePath: tableProDir.appendingPathComponent("known_hosts").path)
    }()
}
