//
//  CloudSQLProxyBinaryManagerTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
import Testing

@testable import TablePro
import TableProTestSupport

enum TestProxyDownload {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudsqlproxy-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pins(_ data: Data) -> [String: String] {
        let digest = sha256(data)
        return ["arm64": digest, "amd64": digest]
    }

    static func response(for url: URL, status: Int) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return response
    }

    // Writes the body to a file, as URLSession's download task does, and records where.
    static func serving(
        _ body: Data,
        status: Int = 200,
        into folder: URL,
        record: DownloadRecord? = nil
    ) -> CloudSQLProxyBinaryManager.Download {
        { url, progress in
            record?.started()
            let file = folder.appendingPathComponent("download-\(UUID().uuidString)")
            try body.write(to: file)
            record?.wrote(file)
            await progress(1)
            return (file, try response(for: url, status: status))
        }
    }
}

final class DownloadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var files: [URL] = []
    private var cancelled = false

    func started() { lock.withLock { startCount += 1 } }
    func wrote(_ file: URL) { lock.withLock { files.append(file) } }
    func sawCancel() { lock.withLock { cancelled = true } }

    var starts: Int { lock.withLock { startCount } }
    var writtenFiles: [URL] { lock.withLock { files } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
}

struct CloudSQLProxyBinaryManagerTests {
    private func install(_ bytes: Data, version: String, into dir: URL) throws {
        let path = dir.appendingPathComponent("cloud-sql-proxy")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        try version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    }

    private func leftovers(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".download") }
    }

    @Test("a matching checksum installs the binary as executable")
    func matchingChecksumInstalls() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let bytes = Data("fake cloud-sql-proxy binary".utf8)
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(bytes),
            download: TestProxyDownload.serving(bytes, into: served)
        )

        let path = try await manager.ensureBinary()

        #expect(FileManager.default.isExecutableFile(atPath: path))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        #expect(await manager.installedVersion() == CloudSQLProxyBinaryManager.pinnedVersion)
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a mismatched checksum on the downloaded file is rejected, nothing is installed and the download is removed")
    func mismatchedChecksumRejected() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let record = DownloadRecord()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": "deadbeef", "amd64": "deadbeef"],
            download: TestProxyDownload.serving(Data("tampered".utf8), into: served, record: record)
        )

        await #expect(throws: CloudSQLProxyError.checksumMismatch) {
            _ = try await manager.ensureBinary()
        }
        #expect(!FileManager.default.fileExists(atPath: manager.binaryExecutablePath))
        #expect(record.writtenFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("an error status is reported with its code instead of as a missing binary")
    func errorStatusIsItsOwnError() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let page = Data("<html>Forbidden</html>".utf8)
        let record = DownloadRecord()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(page),
            download: TestProxyDownload.serving(page, status: 403, into: served, record: record)
        )

        await #expect(throws: CloudSQLProxyError.downloadFailed(statusCode: 403)) {
            _ = try await manager.ensureBinary()
        }
        #expect(!FileManager.default.fileExists(atPath: manager.binaryExecutablePath))
        #expect(record.writtenFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(CloudSQLProxyError.downloadFailed(statusCode: 403).localizedDescription.contains("403"))
    }

    @Test("a failed reinstall keeps the binary that was there", arguments: [403, 200])
    func failedReinstallKeepsOldBinary(status: Int) async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let old = Data("older build".utf8)
        try install(old, version: "0.0.1", into: dir)
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": "deadbeef", "amd64": "deadbeef"],
            download: TestProxyDownload.serving(Data("not the pinned build".utf8), status: status, into: served)
        )

        await #expect(throws: CloudSQLProxyError.self) {
            _ = try await manager.ensureBinary()
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: manager.binaryExecutablePath)) == old)
        #expect(FileManager.default.isExecutableFile(atPath: manager.binaryExecutablePath))
    }

    @Test("a cancel that lands as the download finishes installs nothing and leaves no file behind")
    func cancelLeavesNoFiles() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let bytes = Data("pinned build".utf8)
        let record = DownloadRecord()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(bytes),
            download: { url, _ in
                let file = served.appendingPathComponent("download-\(UUID().uuidString)")
                try bytes.write(to: file)
                record.wrote(file)
                record.started()
                await suspendUntilCancelled()
                record.sawCancel()
                return (file, try TestProxyDownload.response(for: url, status: 200))
            }
        )

        let installing = Task { try await manager.ensureBinary() }
        try await waitUntil { record.starts == 1 }
        installing.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await installing.value
        }
        #expect(record.wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: manager.binaryExecutablePath))
        #expect(record.writtenFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("an installed binary at the pinned version with a matching checksum does not download")
    func currentInstallShortCircuits() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let bytes = Data("already here".utf8)
        try install(bytes, version: CloudSQLProxyBinaryManager.pinnedVersion, into: dir)

        let record = DownloadRecord()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(bytes),
            download: TestProxyDownload.serving(Data(), into: served, record: record)
        )

        let path = try await manager.ensureBinary()

        #expect(path == dir.appendingPathComponent("cloud-sql-proxy").path)
        #expect(record.starts == 0)
    }

    @Test("an installed binary behind the pinned version is replaced")
    func staleVersionIsReplaced() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        try install(Data("older build".utf8), version: "0.0.1", into: dir)

        let fresh = Data("pinned build".utf8)
        let record = DownloadRecord()
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(fresh),
            download: TestProxyDownload.serving(fresh, into: served, record: record)
        )

        let path = try await manager.ensureBinary()

        #expect(record.starts == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fresh)
        #expect(FileManager.default.isExecutableFile(atPath: path))
        #expect(await manager.installedVersion() == CloudSQLProxyBinaryManager.pinnedVersion)
    }

    @Test("an installed binary with no version record is replaced")
    func missingVersionRecordIsReplaced() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let existing = dir.appendingPathComponent("cloud-sql-proxy")
        try Data("no version file".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)

        let fresh = Data("pinned build".utf8)
        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(fresh),
            download: TestProxyDownload.serving(fresh, into: served)
        )

        _ = try await manager.ensureBinary()

        #expect(try Data(contentsOf: existing) == fresh)
    }

    @Test("a binary altered on disk is refused and replaced")
    func alteredBinaryIsReplaced() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        let fresh = Data("pinned build".utf8)
        try install(Data("swapped in later".utf8), version: CloudSQLProxyBinaryManager.pinnedVersion, into: dir)

        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(fresh),
            download: TestProxyDownload.serving(fresh, into: served)
        )

        #expect(!(await manager.installedBinaryIsCurrent()))

        let path = try await manager.ensureBinary()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fresh)
    }

    @Test("a binary altered on disk that cannot be replaced is refused rather than run")
    func alteredBinaryWithFailedRefetchThrows() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        let served = try TestProxyDownload.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: served)
        }

        try install(Data("swapped in later".utf8), version: CloudSQLProxyBinaryManager.pinnedVersion, into: dir)

        let manager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": "deadbeef", "amd64": "deadbeef"],
            download: TestProxyDownload.serving(Data("still wrong".utf8), into: served)
        )

        await #expect(throws: CloudSQLProxyError.checksumMismatch) {
            _ = try await manager.ensureBinary()
        }
        #expect(!(await manager.installedBinaryIsCurrent()))
    }
}

func suspendUntilCancelled() async {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    await withTaskCancellationHandler {
        for await _ in stream {}
    } onCancel: {
        continuation.finish()
    }
}
