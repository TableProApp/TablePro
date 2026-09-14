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

    @Test("A snapshot fetch clears a stale write-ahead log and shared-memory index")
    func snapshotClearsStaleSidecars() throws {
        let directory = try temporaryDirectory()
        let fileName = "app.db"
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(fileName + suffix))
        }
        RemoteDatabaseFileTransfer.clearStaleSidecars(
            layout: .sqliteFamily,
            plan: .remoteSnapshot(executable: "sqlite3"),
            destinationDirectory: directory,
            fileName: fileName
        )
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
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
            plan: .directCopy(sidecars: ["-wal"]),
            destinationDirectory: directory,
            fileName: fileName
        )
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName + "-wal").path))
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
