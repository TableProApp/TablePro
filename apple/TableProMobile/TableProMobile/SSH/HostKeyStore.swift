import Foundation
import TableProSSHTransport

extension HostKeyStore {
    nonisolated static let shared: HostKeyStore = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return HostKeyStore(filePath: NSTemporaryDirectory() + "TablePro_known_hosts")
        }
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return HostKeyStore(filePath: appSupport.appendingPathComponent("known_hosts").path)
    }()
}
