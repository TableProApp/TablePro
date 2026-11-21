import Foundation
import TableProSSHTransport
import Testing

@testable import TableProMobile

struct HostKeyStorePathTests {
    @Test("Host keys stay in known_hosts in Application Support, where earlier releases read them")
    func knownHostsPath() throws {
        let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)

        #expect(HostKeyStore.shared.filePath == appSupport.appendingPathComponent("known_hosts").path)
    }
}
