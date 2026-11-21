import Foundation
import TableProSSHTransport
import Testing

@testable import TablePro

struct HostKeyStorePathTests {
    @Test("Host keys stay in TablePro/known_hosts under the storage root, where earlier releases read them")
    func knownHostsPath() {
        let expected = AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro")
            .appendingPathComponent("known_hosts")
            .path

        #expect(HostKeyStore.shared.filePath == expected)
    }
}
