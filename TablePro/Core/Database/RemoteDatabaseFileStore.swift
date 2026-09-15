//
//  RemoteDatabaseFileStore.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

/// Names the remote file a working copy belongs to.
///
/// The identity is the SSH account and the path, never the connection id. A connection can be
/// duplicated, edited to point somewhere else, or synced to another Mac, and in each case the id
/// says nothing about which bytes are on disk. Two connections naming the same file share one
/// working copy, which is what stops them writing over each other.
struct RemoteFileIdentity: Hashable, Sendable {
    let username: String
    let host: String
    let port: Int
    let path: String

    var displayOrigin: String {
        username.isEmpty ? "\(host):\(path)" : "\(username)@\(host):\(path)"
    }

    /// A stable directory name. Hashed rather than escaped because a remote path can be longer than
    /// a file name may be, and can hold any byte except NUL.
    var storageKey: String {
        let material = "\(username)\n\(host)\n\(port)\n\(path)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the app knows about a working copy without opening it.
///
/// Written beside the copy so a relaunch after a crash can still tell the user what they have and
/// where it came from. `downloadedSHA256` is the hash of the bytes that arrived, so a later
/// comparison can say whether the user changed anything without keeping a second copy.
struct RemoteFileManifest: Codable, Sendable, Equatable {
    let origin: String
    let username: String
    let host: String
    let port: Int
    let remotePath: String
    let fetchedAt: Date
    var remoteSize: UInt64
    var remoteModified: Date

    /// The log's size when the copy was taken, and nil when there was none.
    ///
    /// Kept because in WAL mode a commit lands here and leaves the main file's size and mtime
    /// untouched, so a baseline without it cannot tell an untouched database from a busy one.
    /// Dropping it also made the very first write-back compare a real size against nothing and
    /// report a conflict that was not there.
    var remoteWriteAheadLogSize: UInt64?

    /// The log's modification time when the copy was taken. Optional, so a manifest written before
    /// this field existed decodes with nil and the copy is refetched once to gain a full baseline.
    var remoteWriteAheadLogModified: Date?

    var downloadedSHA256: String
    let snapshotMethod: RemoteSnapshotMethod
    var fingerprint: RemoteFileFingerprint {
        RemoteFileFingerprint(
            mainSize: remoteSize,
            mainModified: remoteModified,
            writeAheadLogSize: remoteWriteAheadLogSize,
            writeAheadLogModified: remoteWriteAheadLogModified
        )
    }

    var identity: RemoteFileIdentity {
        RemoteFileIdentity(username: username, host: host, port: port, path: remotePath)
    }
}

/// How a working copy was taken, which decides how much the app may promise about it.
enum RemoteSnapshotMethod: String, Codable, Sendable {
    /// The server ran `VACUUM INTO`, which SQLite documents as safe while other processes write.
    case remoteSnapshot

    /// The bytes were copied straight off the server along with any sidecar carrying committed
    /// data. Correct when nothing else is writing, and not otherwise.
    case directCopy

    var isConsistentUnderConcurrentWriters: Bool { self == .remoteSnapshot }
}

/// Owns the local copies of remote database files.
///
/// They live under Application Support rather than Caches, so a copy survives the system deciding
/// to reclaim space and a large database is not re-fetched for that reason alone.
/// `.swiftlint.yml` blocks resolving the Application Support directory anywhere but
/// `AppStorageEnvironment`, and does not block `.cachesDirectory`, so the wrong choice here would
/// have passed every check.
actor RemoteDatabaseFileStore {
    static let shared = RemoteDatabaseFileStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteDatabaseFile")
    static let manifestName = "manifest.json"

    private var inFlight: [RemoteFileIdentity: Waiters] = [:]

    private var root: URL {
        AppStorageEnvironment.shared.supportDirectory
            .appendingPathComponent("RemoteDatabaseFiles", isDirectory: true)
    }

    func directory(for identity: RemoteFileIdentity) -> URL {
        root.appendingPathComponent(identity.storageKey, isDirectory: true)
    }

    func workingCopyURL(for identity: RemoteFileIdentity, fileName: String) -> URL {
        directory(for: identity).appendingPathComponent(fileName)
    }

    func prepareDirectory(for identity: RemoteFileIdentity) throws -> URL {
        let directory = directory(for: identity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Manifest

    func manifest(for identity: RemoteFileIdentity) -> RemoteFileManifest? {
        let url = directory(for: identity).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.remoteFileDecoder.decode(RemoteFileManifest.self, from: data)
    }

    func writeManifest(_ manifest: RemoteFileManifest, for identity: RemoteFileIdentity) throws {
        let directory = try prepareDirectory(for: identity)
        let data = try JSONEncoder.remoteFileEncoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: - Exclusion

    /// Serializes every fetch and write-back that names one remote file, across every window and
    /// every connection in this process.
    ///
    /// Two connections can name the same file, and nothing stops a user opening both. Without this
    /// their uploads interleave and either one can replace the other's temp file before the rename
    /// promotes it. `SSHTunnelManager` fences by connection id for the same reason; the key here is
    /// the file, because the file is what is shared.
    func withExclusiveAccess<T: Sendable>(
        to identity: RemoteFileIdentity,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        while let existing = inFlight[identity] {
            await withCheckedContinuation { continuation in
                existing.append(continuation)
            }
        }

        let waiters = Waiters()
        inFlight[identity] = waiters
        defer {
            inFlight[identity] = nil
            waiters.releaseAll()
        }

        return try await operation()
    }

    /// Everyone queued behind one operation on one file.
    ///
    /// A `Task` cannot stand in for this: a task whose body is empty finishes immediately, so
    /// awaiting it releases every waiter at once while the operation it was meant to fence is still
    /// running. The continuations are held until the operation actually returns.
    final class Waiters {
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func append(_ continuation: CheckedContinuation<Void, Never>) {
            continuations.append(continuation)
        }

        func releaseAll() {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    // MARK: - Housekeeping

    func discard(_ identity: RemoteFileIdentity) {
        try? FileManager.default.removeItem(at: directory(for: identity))
        Self.logger.info("Discarded the working copy for \(identity.displayOrigin, privacy: .public)")
    }

    /// Marks a copy as used, so a reuse counts against the abandonment clock the same as a fresh
    /// fetch. Reading a file does not move a directory's modification time, so reuse would otherwise
    /// leave a copy that is opened daily looking abandoned once the server stopped changing.
    func touch(_ identity: RemoteFileIdentity) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: directory(for: identity).path
        )
    }

    /// Removes working copies nothing has used within `maxAge`, which is how a copy left behind by a
    /// deleted connection or a changed path is eventually reclaimed. Nothing else deletes them:
    /// `discard` has no routine caller, because a copy keyed by the resolved server path cannot be
    /// found from a connection's unresolved one at delete time.
    ///
    /// Sweeping a copy is safe. A remote file connection is read-only and re-fetches on next open,
    /// so a removed copy costs one download and never loses data. This runs at launch, before any
    /// connection materializes a copy, so removing one that is about to be reopened only means it is
    /// fetched again. The directory's modification time is the last-used mark, moved forward by a
    /// fresh fetch and by `touch` on every reuse.
    func pruneAbandoned(olderThan maxAge: TimeInterval = 30 * 24 * 60 * 60, now: Date = Date()) {
        Self.pruneAbandoned(in: root, olderThan: maxAge, now: now)
    }

    /// The filesystem half of `pruneAbandoned`, taking its root explicitly so a test can point it at
    /// a temporary directory rather than the app's real store.
    static func pruneAbandoned(in root: URL, olderThan maxAge: TimeInterval, now: Date) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maxAge else { continue }
            try? fileManager.removeItem(at: url)
            logger.info("Pruned a remote database working copy unused for over \(Int(maxAge / 86_400)) days")
        }
    }
}

private extension JSONEncoder {
    static var remoteFileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var remoteFileDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
