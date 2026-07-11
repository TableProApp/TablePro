//
//  CloudSQLProxyBinaryManagerTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
import Testing

@testable import TablePro

@Suite("Cloud SQL Auth Proxy binary manager")
struct CloudSQLProxyBinaryManagerTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudsqlproxy-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("a matching checksum installs the binary as executable")
    func matchingChecksumInstalls() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data("fake cloud-sql-proxy binary".utf8)
        let digest = hash(bytes)
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": digest, "amd64": digest],
            fetch: { _ in bytes }
        )

        let path = try await manager.ensureBinary()

        #expect(FileManager.default.isExecutableFile(atPath: path))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        #expect(await manager.installedVersion() == CloudSQLProxyBinaryManager.pinnedVersion)
    }

    @Test("a mismatched checksum is rejected and nothing is installed")
    func mismatchedChecksumRejected() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": "deadbeef", "amd64": "deadbeef"],
            fetch: { _ in Data("tampered".utf8) }
        )

        await #expect(throws: CloudSQLProxyError.binaryNotFound) {
            _ = try await manager.ensureBinary()
        }
        #expect(await manager.cachedBinaryPath == nil)
    }

    @Test("an already-installed binary short-circuits without fetching")
    func alreadyInstalledShortCircuits() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("cloud-sql-proxy")
        try Data("already here".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)

        let fetched = LockedFlag()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            fetch: { _ in
                fetched.set()
                return Data()
            }
        )

        let path = try await manager.ensureBinary()
        #expect(path == existing.path)
        #expect(!fetched.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
