//
//  HostKeyStoreTests.swift
//  TableProMobileTests
//

import Foundation
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

    @Test("Fingerprints use the OpenSSH SHA256 form")
    func fingerprintFormat() {
        let fingerprint = HostKeyStore.fingerprint(of: Data("tablepro".utf8))
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(!fingerprint.contains("="))
    }
}
