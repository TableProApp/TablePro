//
//  RemoteDatabaseFileCorrectnessTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct RemoteDatabaseFileCorrectnessTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fingerprint

    @Test("A commit that moves only the write-ahead log's mtime is a change")
    func walModifiedIsAChange() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let recorded = RemoteFileFingerprint(
            mainSize: 32_768, mainModified: base, writeAheadLogSize: 234_872, writeAheadLogModified: base
        )
        let current = RemoteFileFingerprint(
            mainSize: 32_768, mainModified: base, writeAheadLogSize: 234_872, writeAheadLogModified: base.addingTimeInterval(5)
        )
        #expect(current.differs(from: recorded))
    }

    @Test("An identical fingerprint including the log mtime is not a change")
    func identicalWithLogMtimeIsNotAChange() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = RemoteFileFingerprint(mainSize: 4_096, mainModified: base, writeAheadLogSize: 100, writeAheadLogModified: base)
        let b = RemoteFileFingerprint(mainSize: 4_096, mainModified: base, writeAheadLogSize: 100, writeAheadLogModified: base)
        #expect(!a.differs(from: b))
    }

    // MARK: - Manifest codec

    @Test("A manifest written before the log mtime field decodes with nil")
    func manifestWithoutLogMtimeDecodesNil() throws {
        let json = Data("""
        {"origin":"u@h:/p","username":"u","host":"h","port":22,"remotePath":"/p",
         "fetchedAt":"2026-01-01T00:00:00Z","remoteSize":4096,"remoteModified":"2026-01-01T00:00:00Z",
         "downloadedSHA256":"abc","snapshotMethod":"directCopy"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RemoteFileManifest.self, from: json)
        #expect(manifest.remoteWriteAheadLogModified == nil)
        #expect(manifest.fingerprint.writeAheadLogModified == nil)
    }

    // MARK: - Stale sidecar clearing

    @Test("A fetch that downloaded no sidecar clears a stale rollback journal, write-ahead log and shared-memory index")
    func fetchWithoutSidecarsClearsEveryStaleSidecar() throws {
        let directory = try temporaryDirectory()
        let fileName = "app.db"
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(fileName + suffix))
        }
        RemoteDatabaseFileTransfer.clearStaleSidecars(
            layout: .sqliteFamily,
            keeping: [],
            destinationDirectory: directory,
            fileName: fileName
        )
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-journal").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-wal").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-shm").path))
    }

    @Test("A direct copy keeps a rollback journal it fetched")
    func directCopyKeepsFetchedJournal() throws {
        let directory = try temporaryDirectory()
        let fileName = "app.db"
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(fileName + suffix))
        }
        RemoteDatabaseFileTransfer.clearStaleSidecars(
            layout: .sqliteFamily,
            keeping: ["-journal"],
            destinationDirectory: directory,
            fileName: fileName
        )
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-journal").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-wal").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-shm").path))
    }

    @Test("A direct copy keeps the log it fetched and clears the shared-memory index")
    func directCopyKeepsFetchedLog() throws {
        let directory = try temporaryDirectory()
        let fileName = "app.db"
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(fileName + suffix))
        }
        RemoteDatabaseFileTransfer.clearStaleSidecars(
            layout: .sqliteFamily,
            keeping: ["-wal"],
            destinationDirectory: directory,
            fileName: fileName
        )
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-wal").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-shm").path))
    }

    @Test("A direct copy clears a stale rollback journal its plan listed but the server had dropped by fetch time")
    func directCopyClearsAJournalTheServerDroppedAfterPlanning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileName = "app.db"
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try Data("stale".utf8).write(to: directory.appendingPathComponent(fileName + suffix))
        }
        let freshLog = Data("fresh log".utf8)
        let server = StubRemoteFileSource(files: ["/srv/app.db-wal": freshLog])

        let fetched = try RemoteDatabaseFileTransfer.fetchSidecars(
            from: server,
            remotePath: "/srv/app.db",
            sidecars: ["-wal", "-journal"],
            destinationDirectory: directory,
            fileName: fileName,
            isCancelled: { false }
        )
        RemoteDatabaseFileTransfer.clearStaleSidecars(
            layout: .sqliteFamily,
            keeping: fetched,
            destinationDirectory: directory,
            fileName: fileName
        )

        #expect(fetched == ["-wal"])
        let log = try Data(contentsOf: directory.appendingPathComponent(fileName + "-wal"))
        #expect(log == freshLog)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-journal").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-shm").path))
    }

    // MARK: - Killed remote command

    @Test("A signal-killed remote command does not report success")
    func signalKilledCommandIsNotSuccess() {
        let killed = RemoteCommandResult(exitStatus: 0, standardOutput: "", standardError: "", exitSignal: "KILL")
        #expect(!killed.succeeded)
        let clean = RemoteCommandResult(exitStatus: 0, standardOutput: "ok", standardError: "", exitSignal: nil)
        #expect(clean.succeeded)
    }

    // MARK: - Prune

    @Test("An abandoned working copy is removed and a recently used one is kept")
    func pruneRemovesOnlyStaleCopies() throws {
        let root = try temporaryDirectory()
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        let stale = root.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let maxAge: TimeInterval = 30 * 24 * 60 * 60
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(maxAge + 86_400))], ofItemAtPath: stale.path
        )

        RemoteDatabaseFileStore.pruneAbandoned(in: root, olderThan: maxAge, now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}

private struct StubRemoteFileSource: RemoteFileSource {
    let files: [String: Data]

    func exists(_ path: String) -> Bool {
        files[path] != nil
    }

    func download(
        remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        guard let data = files[remotePath] else {
            throw SFTPError.noSuchFile(path: remotePath)
        }
        try data.write(to: localURL)
        return (bytes: UInt64(data.count), sha256: "")
    }
}
