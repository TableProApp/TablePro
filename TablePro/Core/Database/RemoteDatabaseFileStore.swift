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

    var downloadedSHA256: String
    let snapshotMethod: RemoteSnapshotMethod
    var fingerprint: RemoteFileFingerprint {
        RemoteFileFingerprint(
            mainSize: remoteSize,
            mainModified: remoteModified,
            writeAheadLogSize: remoteWriteAheadLogSize
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
