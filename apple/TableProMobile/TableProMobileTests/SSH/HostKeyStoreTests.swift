import Foundation
import TableProSSHTransport
import Testing

@testable import TableProMobile

@Suite("HostKeyStore")
struct HostKeyStoreTests {
    private func makeTempFilePath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("test_known_hosts_\(UUID().uuidString)")
    }

    private func makeTestKey(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: 32)
    }

    @Test("An unseen host is unknown, not trusted")
    func unknownHostIsNotTrusted() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key = makeTestKey(0xAA)

        #expect(
            store.verify(keyData: key, keyType: "ssh-ed25519", hostname: "db.example.com", port: 22)
                == .unknown(fingerprint: HostKeyStore.fingerprint(of: key), keyType: "ssh-ed25519")
        )
    }

    @Test("A trusted key verifies on the next connect")
    func trustedKeyVerifies() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key = makeTestKey(0xBB)

        store.trust(hostname: "db.example.com", port: 22, key: key, keyType: "ssh-ed25519")

        #expect(store.verify(keyData: key, keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .trusted)
    }

    @Test("A changed key is a mismatch")
    func changedKeyIsMismatch() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let trusted = makeTestKey(0xCC)
        let presented = makeTestKey(0xDD)

        store.trust(hostname: "db.example.com", port: 22, key: trusted, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: presented, keyType: "ssh-ed25519", hostname: "db.example.com", port: 22)
                == .mismatch(
                    expected: HostKeyStore.fingerprint(of: trusted),
                    actual: HostKeyStore.fingerprint(of: presented)
                )
        )
    }

    @Test("A different key type for a known host is a mismatch, not a first-use prompt")
    func differentKeyTypeIsMismatch() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let trusted = makeTestKey(0xEE)
        let attacker = makeTestKey(0xEF)

        store.trust(hostname: "db.example.com", port: 22, key: trusted, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: attacker, keyType: "ssh-rsa", hostname: "db.example.com", port: 22)
                == .mismatch(
                    expected: HostKeyStore.fingerprint(of: trusted),
                    actual: HostKeyStore.fingerprint(of: attacker)
                )
        )
    }

    @Test("Hosts on different ports are tracked separately")
    func portsAreSeparateEntries() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key = makeTestKey(0x11)

        store.trust(hostname: "db.example.com", port: 22, key: key, keyType: "ssh-ed25519")

        #expect(store.verify(keyData: key, keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .trusted)
        if case .trusted = store.verify(
            keyData: key, keyType: "ssh-ed25519", hostname: "db.example.com", port: 2222
        ) {
            Issue.record("Port 2222 should not inherit trust from port 22")
        }
    }

    @Test("Removing a host clears every key type stored for it")
    func removeClearsAllKeyTypes() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        store.trust(hostname: "db.example.com", port: 22, key: makeTestKey(0x21), keyType: "ssh-rsa")
        store.trust(hostname: "db.example.com", port: 22, key: makeTestKey(0x22), keyType: "ssh-ed25519")

        store.remove(hostname: "db.example.com", port: 22)

        #expect(store.trustedHosts().isEmpty)
    }

    @Test("A saved key file that cannot be read checks no key and is never written over")
    func unreadableFileChecksNothing() throws {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        store.trust(hostname: "db.example.com", port: 22, key: makeTestKey(0x31), keyType: "ssh-ed25519")
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        #expect(
            store.verify(keyData: makeTestKey(0x32), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22)
                == .unreadable
        )
        store.trust(hostname: "other.example.com", port: 22, key: makeTestKey(0x33), keyType: "ssh-ed25519")
        store.remove(hostname: "db.example.com", port: 22)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let after = try String(contentsOfFile: path, encoding: .utf8)
        #expect(after == saved)
        #expect(store.verify(keyData: makeTestKey(0x31), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .trusted)
    }

    @Test("A saved line that cannot be parsed keeps its host from looking new, and stays in the file")
    func unparsedLineIsKept() throws {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let unparsed = "[db.example.com]:22 ssh-ed25519 !!not-base64!!"
        try (unparsed + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let store = HostKeyStore(filePath: path)

        #expect(
            store.verify(keyData: makeTestKey(0x41), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22)
                == .unreadable
        )
        store.trust(hostname: "other.example.com", port: 22, key: makeTestKey(0x42), keyType: "ssh-ed25519")

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.hasPrefix(unparsed + "\n"))
        #expect(store.verify(keyData: makeTestKey(0x42), keyType: "ssh-ed25519", hostname: "other.example.com", port: 22) == .trusted)
    }

    @Test("Fingerprints use the OpenSSH SHA256 form")
    func fingerprintFormat() {
        let fingerprint = HostKeyStore.fingerprint(of: Data("tablepro".utf8))
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(!fingerprint.contains("="))
    }

    @Test("A host with a line break plants no key for another host", arguments: [
        "replica.attacker.example\n[prod.corp.example",
        "replica.attacker.example\r\n[prod.corp.example",
        "replica.attacker.example [prod.corp.example",
    ])
    func lineBreakInHostPlantsNoEntry(hostile: String) {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let real = makeTestKey(0x01)
        let forged = makeTestKey(0x02)
        store.trust(hostname: "prod.corp.example", port: 22, key: real, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: forged, keyType: "ssh-ed25519", hostname: hostile, port: 22)
                == .invalidHost(.host(hostile))
        )
        store.trust(hostname: hostile, port: 22, key: forged, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: forged, keyType: "ssh-ed25519", hostname: "prod.corp.example", port: 22)
                == .mismatch(expected: HostKeyStore.fingerprint(of: real), actual: HostKeyStore.fingerprint(of: forged))
        )
        #expect(store.verify(keyData: real, keyType: "ssh-ed25519", hostname: "prod.corp.example", port: 22) == .trusted)
    }
}
