import Foundation
import Testing

@testable import TableProMobile

@Suite("SSH tunnel credentials")
struct SSHTunnelCredentialsTests {
    @Test("Reads the password, passphrase and key stored for that connection only")
    func readsOneConnection() {
        let id = UUID()
        let other = UUID()
        let store = MockSecureStore()
        store.seed("com.TablePro.sshpassword.\(id.uuidString)", "ssh-secret")
        store.seed("com.TablePro.keypassphrase.\(id.uuidString)", "phrase")
        store.seed("com.TablePro.sshkeydata.\(id.uuidString)", "KEY")
        store.seed("com.TablePro.sshkeydata.\(other.uuidString)", "OTHER KEY")

        let credentials = SSHTunnelCredentials(connectionId: id, secureStore: store)

        #expect(credentials == SSHTunnelCredentials(password: "ssh-secret", keyPassphrase: "phrase", privateKey: "KEY"))
    }

    @Test("Empty stored values read as absent")
    func emptyIsAbsent() {
        let id = UUID()
        let store = MockSecureStore()
        store.seed("com.TablePro.sshpassword.\(id.uuidString)", "")
        store.seed("com.TablePro.keypassphrase.\(id.uuidString)", "")
        store.seed("com.TablePro.sshkeydata.\(id.uuidString)", "")

        let credentials = SSHTunnelCredentials(connectionId: id, secureStore: store)

        #expect(credentials.password == nil)
        #expect(credentials.keyPassphrase == nil)
        #expect(credentials.privateKey == nil)
    }

    @Test("A stored key wins over a key file")
    func storedKeyWins() {
        let credentials = SSHTunnelCredentials(privateKey: "KEY")
        #expect(credentials.privateKeySource(keyPath: "/keys/id_ed25519") == .inMemory("KEY"))
    }

    @Test("A key file is used when no key is stored")
    func keyFileWithoutStoredKey() {
        let credentials = SSHTunnelCredentials()
        #expect(credentials.privateKeySource(keyPath: "/keys/id_ed25519") == .file(path: "/keys/id_ed25519"))
    }

    @Test("No stored key and no key file leaves nothing to authenticate with")
    func neitherIsMissing() {
        let credentials = SSHTunnelCredentials()
        #expect(credentials.privateKeySource(keyPath: nil) == .missing)
        #expect(credentials.privateKeySource(keyPath: "") == .missing)
    }
}
