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
        #expect(!(await manager.isInstalled))
    }

    /// Writes a binary that looks installed, so a test can vary one of the two things
    /// `installedBinaryIsCurrent` checks and leave the other correct.
    private func install(
        _ bytes: Data,
        version: String,
        into dir: URL
    ) throws {
        let path = dir.appendingPathComponent("cloud-sql-proxy")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        try version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    }

    @Test("an installed binary at the pinned version with a matching checksum does not fetch")
    func currentInstallShortCircuits() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data("already here".utf8)
        try install(bytes, version: CloudSQLProxyBinaryManager.pinnedVersion, into: dir)

        let digest = hash(bytes)
        let fetched = LockedFlag()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": digest, "amd64": digest],
            fetch: { _ in
                fetched.set()
                return Data()
            }
        )

        let path = try await manager.ensureBinary()

        #expect(path == dir.appendingPathComponent("cloud-sql-proxy").path)
        #expect(!fetched.value)
    }

    @Test("an installed binary behind the pinned version is replaced")
    func staleVersionIsReplaced() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stale = Data("older build".utf8)
        try install(stale, version: "0.0.1", into: dir)

        let fresh = Data("pinned build".utf8)
        let digest = hash(fresh)
        let fetched = LockedFlag()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": digest, "amd64": digest],
            fetch: { _ in
                fetched.set()
                return fresh
            }
        )

        let path = try await manager.ensureBinary()

        #expect(fetched.value)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fresh)
        #expect(await manager.installedVersion() == CloudSQLProxyBinaryManager.pinnedVersion)
    }

    @Test("an installed binary with no version record is replaced")
    func missingVersionRecordIsReplaced() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("cloud-sql-proxy")
        try Data("no version file".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)

        let fresh = Data("pinned build".utf8)
        let digest = hash(fresh)
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": digest, "amd64": digest],
            fetch: { _ in fresh }
        )

        _ = try await manager.ensureBinary()

        #expect(try Data(contentsOf: existing) == fresh)
    }

    @Test("a binary altered on disk is refused and replaced")
    func alteredBinaryIsReplaced() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fresh = Data("pinned build".utf8)
        let digest = hash(fresh)

        try install(Data("swapped in later".utf8), version: CloudSQLProxyBinaryManager.pinnedVersion, into: dir)

        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": digest, "amd64": digest],
            fetch: { _ in fresh }
        )

        #expect(!(await manager.installedBinaryIsCurrent()))

        let path = try await manager.ensureBinary()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fresh)
    }

    @Test("a binary altered on disk that cannot be replaced is refused rather than run")
    func alteredBinaryWithFailedRefetchThrows() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try install(Data("swapped in later".utf8), version: CloudSQLProxyBinaryManager.pinnedVersion, into: dir)

        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": "deadbeef", "amd64": "deadbeef"],
            fetch: { _ in Data("still wrong".utf8) }
        )

        await #expect(throws: CloudSQLProxyError.binaryNotFound) {
            _ = try await manager.ensureBinary()
        }
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
