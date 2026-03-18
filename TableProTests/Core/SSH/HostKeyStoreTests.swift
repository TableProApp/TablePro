//
//  HostKeyStoreTests.swift
//  TableProTests
//
//  Tests for HostKeyStore file-based SSH host key storage.
//

import Foundation
import Testing

@testable import TablePro

@Suite("HostKeyStore")
struct HostKeyStoreTests {
    /// Create a temporary file path for test isolation
    private func makeTempFilePath() -> String {
        let tempDir = NSTemporaryDirectory()
        return (tempDir as NSString).appendingPathComponent("test_known_hosts_\(UUID().uuidString)")
    }

    /// Create a deterministic test key
    private func makeTestKey(_ seed: UInt8 = 0x42, length: Int = 32) -> Data {
        Data(repeating: seed, count: length)
    }

    @Test("Trust a host and verify returns .trusted")
    func testTrustAndVerify() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key = makeTestKey(0xAA)

        store.trust(hostname: "example.com", port: 22, key: key, keyType: "ssh-rsa")

        let result = store.verify(keyData: key, keyType: "ssh-rsa", hostname: "example.com", port: 22)
        #expect(result == .trusted)
    }

    @Test("Verify unknown host returns .unknown with fingerprint and key type")
    func testUnknownHost() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key = makeTestKey(0xBB)
        let expectedFingerprint = HostKeyStore.fingerprint(of: key)

        let result = store.verify(keyData: key, keyType: "ssh-ed25519", hostname: "unknown.host", port: 22)
        #expect(result == .unknown(fingerprint: expectedFingerprint, keyType: "ssh-ed25519"))
    }

    @Test("Changed key returns .mismatch with expected and actual fingerprints")
    func testMismatch() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let originalKey = makeTestKey(0xCC)
        let changedKey = makeTestKey(0xDD)

        store.trust(hostname: "example.com", port: 22, key: originalKey, keyType: "ssh-rsa")

        let expectedFingerprint = HostKeyStore.fingerprint(of: originalKey)
        let actualFingerprint = HostKeyStore.fingerprint(of: changedKey)

        let result = store.verify(keyData: changedKey, keyType: "ssh-rsa", hostname: "example.com", port: 22)
        #expect(result == .mismatch(expected: expectedFingerprint, actual: actualFingerprint))
    }

    @Test("Remove a host key then verify returns .unknown")
    func testRemove() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key = makeTestKey(0xEE)

        store.trust(hostname: "example.com", port: 22, key: key, keyType: "ssh-rsa")
        #expect(store.verify(keyData: key, keyType: "ssh-rsa", hostname: "example.com", port: 22) == .trusted)

        store.remove(hostname: "example.com", port: 22)

        let result = store.verify(keyData: key, keyType: "ssh-rsa", hostname: "example.com", port: 22)
        switch result {
        case .unknown:
            break // expected
        default:
            Issue.record("Expected .unknown after removal, got \(result)")
        }
    }

    @Test("SHA256 fingerprint format is correct")
    func testFingerprint() {
        let key = makeTestKey(0xFF, length: 64)
        let fingerprint = HostKeyStore.fingerprint(of: key)

        #expect(fingerprint.hasPrefix("SHA256:"))

        // Fingerprint should not contain '=' padding (matches OpenSSH format)
        #expect(!fingerprint.contains("="))

        // Same key should produce the same fingerprint
        let fingerprint2 = HostKeyStore.fingerprint(of: key)
        #expect(fingerprint == fingerprint2)

        // Different key should produce a different fingerprint
        let otherKey = makeTestKey(0x00, length: 64)
        let otherFingerprint = HostKeyStore.fingerprint(of: otherKey)
        #expect(fingerprint != otherFingerprint)
    }

    @Test("Multiple hosts are stored and verified independently")
    func testMultipleHosts() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key1 = makeTestKey(0x11)
        let key2 = makeTestKey(0x22)
        let key3 = makeTestKey(0x33)

        store.trust(hostname: "host-a.com", port: 22, key: key1, keyType: "ssh-rsa")
        store.trust(hostname: "host-b.com", port: 22, key: key2, keyType: "ssh-ed25519")
        store.trust(hostname: "host-c.com", port: 22, key: key3, keyType: "ecdsa-sha2-nistp256")

        #expect(store.verify(keyData: key1, keyType: "ssh-rsa", hostname: "host-a.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key2, keyType: "ssh-ed25519", hostname: "host-b.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key3, keyType: "ecdsa-sha2-nistp256", hostname: "host-c.com", port: 22) == .trusted)

        // Removing one host should not affect others
        store.remove(hostname: "host-b.com", port: 22)
        #expect(store.verify(keyData: key1, keyType: "ssh-rsa", hostname: "host-a.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key3, keyType: "ecdsa-sha2-nistp256", hostname: "host-c.com", port: 22) == .trusted)
    }

    @Test("Same hostname with different ports are separate entries")
    func testPortDifferentiation() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let key22 = makeTestKey(0x44)
        let key2222 = makeTestKey(0x55)

        store.trust(hostname: "example.com", port: 22, key: key22, keyType: "ssh-rsa")
        store.trust(hostname: "example.com", port: 2222, key: key2222, keyType: "ssh-ed25519")

        #expect(store.verify(keyData: key22, keyType: "ssh-rsa", hostname: "example.com", port: 22) == .trusted)
        #expect(store.verify(keyData: key2222, keyType: "ssh-ed25519", hostname: "example.com", port: 2222) == .trusted)

        // Key from port 22 should not match port 2222
        let result = store.verify(keyData: key22, keyType: "ssh-rsa", hostname: "example.com", port: 2222)
        switch result {
        case .mismatch:
            break // expected — different key stored for this port
        default:
            Issue.record("Expected .mismatch when using wrong port's key, got \(result)")
        }
    }

    @Test("Key type name mapping from numeric constants")
    func testKeyTypeName() {
        #expect(HostKeyStore.keyTypeName(1) == "ssh-rsa")
        #expect(HostKeyStore.keyTypeName(2) == "ssh-dss")
        #expect(HostKeyStore.keyTypeName(3) == "ecdsa-sha2-nistp256")
        #expect(HostKeyStore.keyTypeName(4) == "ecdsa-sha2-nistp384")
        #expect(HostKeyStore.keyTypeName(5) == "ecdsa-sha2-nistp521")
        #expect(HostKeyStore.keyTypeName(6) == "ssh-ed25519")
        #expect(HostKeyStore.keyTypeName(0) == "unknown")
        #expect(HostKeyStore.keyTypeName(99) == "unknown")
    }

    @Test("Trusting the same host and key type again updates the stored key")
    func testTrustUpdatesExistingEntry() {
        let path = makeTempFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = HostKeyStore(filePath: path)
        let oldKey = makeTestKey(0x66)
        let newKey = makeTestKey(0x77)

        store.trust(hostname: "example.com", port: 22, key: oldKey, keyType: "ssh-rsa")
        #expect(store.verify(keyData: oldKey, keyType: "ssh-rsa", hostname: "example.com", port: 22) == .trusted)

        // Trust with new key (same key type)
        store.trust(hostname: "example.com", port: 22, key: newKey, keyType: "ssh-rsa")
        #expect(store.verify(keyData: newKey, keyType: "ssh-rsa", hostname: "example.com", port: 22) == .trusted)

        // Old key should no longer match
        let result = store.verify(keyData: oldKey, keyType: "ssh-rsa", hostname: "example.com", port: 22)
        switch result {
        case .mismatch:
            break // expected
        default:
            Issue.record("Expected .mismatch for old key after update, got \(result)")
        }
    }
}
