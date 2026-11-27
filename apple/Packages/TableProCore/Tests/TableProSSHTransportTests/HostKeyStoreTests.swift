import Foundation
import Testing

@testable import TableProSSHTransport

struct HostKeyStoreTests {
    private func key(_ seed: UInt8, length: Int = 32) -> Data {
        Data(repeating: seed, count: length)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("known_hosts_\(UUID().uuidString)").path
    }

    @Test("An unseen host is unknown, with the presented key's fingerprint and type")
    func unknownHost() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)

        #expect(
            store.verify(keyData: key(0xAA), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22)
                == .unknown(fingerprint: HostKeyStore.fingerprint(of: key(0xAA)), keyType: "ssh-ed25519")
        )
    }

    @Test("A trusted key verifies on the next connect")
    func trustedKeyVerifies() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)

        store.trust(hostname: "db.example.com", port: 22, key: key(0xBB), keyType: "ssh-ed25519")

        #expect(store.verify(keyData: key(0xBB), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .trusted)
    }

    @Test("A changed key is a mismatch naming both fingerprints")
    func changedKeyIsMismatch() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        let trusted = key(0xCC)
        let presented = key(0xDD)

        store.trust(hostname: "db.example.com", port: 22, key: trusted, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: presented, keyType: "ssh-ed25519", hostname: "db.example.com", port: 22)
                == .mismatch(expected: HostKeyStore.fingerprint(of: trusted), actual: HostKeyStore.fingerprint(of: presented))
        )
    }

    @Test("A different key type for a known host is a mismatch, not a first-use prompt")
    func differentKeyTypeIsMismatch() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        let trusted = key(0xEE)
        let attacker = key(0xEF)

        store.trust(hostname: "db.example.com", port: 22, key: trusted, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: attacker, keyType: "ssh-rsa", hostname: "db.example.com", port: 22)
                == .mismatch(expected: HostKeyStore.fingerprint(of: trusted), actual: HostKeyStore.fingerprint(of: attacker))
        )
    }

    @Test("A host trusted under two key types verifies either one")
    func eitherTrustedKeyTypeVerifies() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)

        store.trust(hostname: "db.example.com", port: 22, key: key(0x11), keyType: "ssh-rsa")
        store.trust(hostname: "db.example.com", port: 22, key: key(0x22), keyType: "ssh-ed25519")

        #expect(store.verify(keyData: key(0x11), keyType: "ssh-rsa", hostname: "db.example.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key(0x22), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .trusted)
    }

    @Test("Trusting the same host and key type again replaces the stored key")
    func trustReplacesKeyOfSameType() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        let old = key(0x66)
        let new = key(0x77)

        store.trust(hostname: "db.example.com", port: 22, key: old, keyType: "ssh-rsa")
        store.trust(hostname: "db.example.com", port: 22, key: new, keyType: "ssh-rsa")

        #expect(store.verify(keyData: new, keyType: "ssh-rsa", hostname: "db.example.com", port: 22) == .trusted)
        #expect(
            store.verify(keyData: old, keyType: "ssh-rsa", hostname: "db.example.com", port: 22)
                == .mismatch(expected: HostKeyStore.fingerprint(of: new), actual: HostKeyStore.fingerprint(of: old))
        )
    }

    @Test("Removing a host clears every key type stored for it")
    func removeClearsAllKeyTypes() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        store.trust(hostname: "db.example.com", port: 22, key: key(0x21), keyType: "ssh-rsa")
        store.trust(hostname: "db.example.com", port: 22, key: key(0x22), keyType: "ssh-ed25519")
        #expect(store.trustedHosts() == ["[db.example.com]:22"])

        store.remove(hostname: "db.example.com", port: 22)

        #expect(store.trustedHosts().isEmpty)
        #expect(
            store.verify(keyData: key(0x21), keyType: "ssh-rsa", hostname: "db.example.com", port: 22)
                == .unknown(fingerprint: HostKeyStore.fingerprint(of: key(0x21)), keyType: "ssh-rsa")
        )
    }

    @Test("Hosts are stored, listed and removed independently")
    func multipleHosts() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)

        store.trust(hostname: "host-c.com", port: 22, key: key(0x33), keyType: "ecdsa-sha2-nistp256")
        store.trust(hostname: "host-a.com", port: 22, key: key(0x11), keyType: "ssh-rsa")
        store.trust(hostname: "host-b.com", port: 22, key: key(0x22), keyType: "ssh-ed25519")

        #expect(store.trustedHosts() == ["[host-a.com]:22", "[host-b.com]:22", "[host-c.com]:22"])
        #expect(store.verify(keyData: key(0x11), keyType: "ssh-rsa", hostname: "host-a.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key(0x22), keyType: "ssh-ed25519", hostname: "host-b.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key(0x33), keyType: "ecdsa-sha2-nistp256", hostname: "host-c.com", port: 22) == .trusted)

        store.remove(hostname: "host-b.com", port: 22)

        #expect(store.trustedHosts() == ["[host-a.com]:22", "[host-c.com]:22"])
        #expect(store.verify(keyData: key(0x11), keyType: "ssh-rsa", hostname: "host-a.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key(0x33), keyType: "ecdsa-sha2-nistp256", hostname: "host-c.com", port: 22) == .trusted)
    }

    @Test("The same host on another port is a separate entry")
    func portsAreSeparateEntries() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        let key22 = key(0x44)
        let key2222 = key(0x55)

        store.trust(hostname: "db.example.com", port: 22, key: key22, keyType: "ssh-rsa")
        #expect(
            store.verify(keyData: key22, keyType: "ssh-rsa", hostname: "db.example.com", port: 2_222)
                == .unknown(fingerprint: HostKeyStore.fingerprint(of: key22), keyType: "ssh-rsa")
        )

        store.trust(hostname: "db.example.com", port: 2_222, key: key2222, keyType: "ssh-ed25519")

        #expect(store.verify(keyData: key22, keyType: "ssh-rsa", hostname: "db.example.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key2222, keyType: "ssh-ed25519", hostname: "db.example.com", port: 2_222) == .trusted)
        #expect(
            store.verify(keyData: key22, keyType: "ssh-rsa", hostname: "db.example.com", port: 2_222)
                == .mismatch(expected: HostKeyStore.fingerprint(of: key2222), actual: HostKeyStore.fingerprint(of: key22))
        )
    }

    @Test("A saved key file that cannot be read checks no key and is never written over")
    func unreadableFileChecksNothing() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        store.trust(hostname: "db.example.com", port: 22, key: key(0x31), keyType: "ssh-ed25519")
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        #expect(store.verify(keyData: key(0x32), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .unreadable)
        store.trust(hostname: "other.example.com", port: 22, key: key(0x33), keyType: "ssh-ed25519")
        store.remove(hostname: "db.example.com", port: 22)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == saved)
        #expect(store.verify(keyData: key(0x31), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .trusted)
    }

    @Test("A saved line that cannot be parsed keeps its host from looking new, and stays in the file")
    func unparsedLineIsKept() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let unparsed = "[db.example.com]:22 ssh-ed25519 !!not-base64!!"
        try (unparsed + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let store = HostKeyStore(filePath: path)

        #expect(store.verify(keyData: key(0x41), keyType: "ssh-ed25519", hostname: "db.example.com", port: 22) == .unreadable)
        store.trust(hostname: "other.example.com", port: 22, key: key(0x42), keyType: "ssh-ed25519")

        #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix(unparsed + "\n"))
        #expect(store.verify(keyData: key(0x42), keyType: "ssh-ed25519", hostname: "other.example.com", port: 22) == .trusted)
    }

    @Test("A host with a line break plants no key for another host", arguments: [
        "replica.attacker.example\n[prod.corp.example",
        "replica.attacker.example\r\n[prod.corp.example",
        "replica.attacker.example [prod.corp.example",
    ])
    func lineBreakInHostPlantsNoEntry(hostile: String) {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HostKeyStore(filePath: path)
        let real = key(0x01)
        let forged = key(0x02)
        store.trust(hostname: "prod.corp.example", port: 22, key: real, keyType: "ssh-ed25519")

        #expect(store.verify(keyData: forged, keyType: "ssh-ed25519", hostname: hostile, port: 22) == .invalidHost(.host(hostile)))
        store.trust(hostname: hostile, port: 22, key: forged, keyType: "ssh-ed25519")

        #expect(
            store.verify(keyData: forged, keyType: "ssh-ed25519", hostname: "prod.corp.example", port: 22)
                == .mismatch(expected: HostKeyStore.fingerprint(of: real), actual: HostKeyStore.fingerprint(of: forged))
        )
        #expect(store.verify(keyData: real, keyType: "ssh-ed25519", hostname: "prod.corp.example", port: 22) == .trusted)
    }

    @Test("Fingerprints use the OpenSSH SHA256 form, base64 without padding")
    func fingerprintFormat() {
        #expect(HostKeyStore.fingerprint(of: Data("tablepro".utf8)) == "SHA256:LFI08RUW/kZD9NjQQxyWL4XFlFJ2S/kXkoDufgqg10w")
        #expect(HostKeyStore.fingerprint(of: key(0xFF, length: 64)) != HostKeyStore.fingerprint(of: key(0x00, length: 64)))
    }

    @Test("libssh2 key type constants map to OpenSSH key type names")
    func keyTypeNames() {
        #expect(HostKeyStore.keyTypeName(1) == "ssh-rsa")
        #expect(HostKeyStore.keyTypeName(2) == "ssh-dss")
        #expect(HostKeyStore.keyTypeName(3) == "ecdsa-sha2-nistp256")
        #expect(HostKeyStore.keyTypeName(4) == "ecdsa-sha2-nistp384")
        #expect(HostKeyStore.keyTypeName(5) == "ecdsa-sha2-nistp521")
        #expect(HostKeyStore.keyTypeName(6) == "ssh-ed25519")
        #expect(HostKeyStore.keyTypeName(0) == "unknown")
        #expect(HostKeyStore.keyTypeName(99) == "unknown")
    }
}
