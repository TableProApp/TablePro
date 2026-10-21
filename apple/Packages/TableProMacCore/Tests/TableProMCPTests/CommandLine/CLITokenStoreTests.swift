import Foundation
@testable import TableProMCP
import Testing

struct CLITokenStoreTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cli-token-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A sandboxed run keeps its token in the sandbox, never the login Keychain")
    func sandboxUsesAFile() {
        let sandbox = scratchDirectory()
        let store = CLITokenStores.current(environment: ["TABLEPRO_UI_TEST_SANDBOX": sandbox.path])
        #expect(store is CLIFileTokenStore)
        #expect(CLITokenStores.current(environment: [:]) is CLIKeychainTokenStore)
        #expect(CLITokenStores.current(environment: ["TABLEPRO_UI_TEST_SANDBOX": "  "]) is CLIKeychainTokenStore)
    }

    @Test("The file store round-trips a token that only its owner can read")
    func fileRoundTrip() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("TablePro/cli-token")
        let store = CLIFileTokenStore(url: url)

        #expect(try store.read() == nil)
        try store.save("tp_one")
        try store.save("tp_two")
        #expect(try store.read() == "tp_two")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        store.delete()
        #expect(try store.read() == nil)
    }
}
