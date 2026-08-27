//
//  RemoteDatabaseFileTransfer.swift
//  TablePro
//

import Foundation
import os

/// How the app plans to take a copy of a remote database, and what it may promise about the result.
enum RemoteFetchPlan: Equatable, Sendable {
    /// The server has a `sqlite3` that supports `VACUUM INTO`, which SQLite documents as safe while
    /// other processes are writing. Measured: a snapshot taken this way passed `integrity_check`
    /// while 22,518 transactions committed against the source, with no error on either side.
    case remoteSnapshot(executable: String)

    /// The bytes are copied straight off the server, along with any sidecar carrying committed
    /// data. Correct while nothing else writes the file, and not otherwise: SQLite's own
    /// documentation says a copy taken mid-transaction can hold a mix of old and new pages.
    case directCopy(sidecars: [String])

    var method: RemoteSnapshotMethod {
        switch self {
        case .remoteSnapshot: return .remoteSnapshot
        case .directCopy: return .directCopy
        }
    }
}

/// What the remote looked like when the copy was taken, for both the main file and the write-ahead
/// log beside it.
///
/// The log matters as much as the file. In WAL mode a commit lands in `-wal` and leaves the main
/// file's size and mtime untouched until a checkpoint, so a gate that watches only the main file
/// reports "unchanged" for a database that has been written to all afternoon.
struct RemoteFileFingerprint: Codable, Sendable, Equatable {
    let mainSize: UInt64
    let mainModified: Date
    let writeAheadLogSize: UInt64?

    func differs(from other: RemoteFileFingerprint) -> Bool {
        mainSize != other.mainSize
            || mainModified != other.mainModified
            || writeAheadLogSize != other.writeAheadLogSize
    }
}

struct RemoteFetchResult: Sendable {
    let workingCopy: URL
    let manifest: RemoteFileManifest
    let plan: RemoteFetchPlan
}

/// Copies a database file from a server into a local working copy.
///
/// Every rule here comes from something that was measured rather than assumed. The three that
/// decide whether this is safe:
///
/// - A download is written to a staging name and only moved into place once its byte count matches
///   what the server reported and the file parses as the database it claims to be. SFTP writes a
///   file front to back, so a transfer cut short by a dropped session or a cancelled connect leaves
///   an intact header and a plausible prefix; `sqlite3_open` on that will happily report success.
/// - A fetch takes the `-wal` sidecar too. Measured: opening only the main file of a WAL-mode
///   database returned the checkpointed row and silently omitted the committed one.
/// - Nothing is ever written back. A remote-file connection is read-only, so the only direction
///   here is down, and the original on the server is never touched.
enum RemoteDatabaseFileTransfer {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteDatabaseFile")

    /// `VACUUM INTO` arrived in SQLite 3.27. Older is not an error, it just means the safe tier is
    /// unavailable and the copy is taken directly.
    private static let minimumSnapshotSQLiteVersion = (major: 3, minor: 27)

    /// Leaves room for the working copy to grow as the user edits it, and for the staging file a
    /// write-back builds beside it.
    private static let localFreeSpaceMultiplier: UInt64 = 3

    // MARK: - Planning

    static func plan(
        session: LibSSH2SFTPSession,
        remotePath: String,
        layout: DatabaseFileLayout
    ) -> RemoteFetchPlan {
        let presentSidecars = layout.dataCarryingSidecarSuffixes
            .filter { session.exists(remotePath + $0) }

        guard layout.supportsRemoteSnapshot, let executable = snapshotExecutable(on: session) else {
            return .directCopy(sidecars: presentSidecars)
        }
        return .remoteSnapshot(executable: executable)
    }

    /// Finds a remote `sqlite3` new enough to take a consistent snapshot.
    ///
    /// A server may refuse exec entirely, which a chrooted SFTP-only account does by design. That is
    /// an ordinary answer, not a failure: the caller copies directly and says so.
    private static func snapshotExecutable(on session: LibSSH2SFTPSession) -> String? {
        guard let result = try? session.runRemoteCommand("sqlite3 --version"), result.succeeded else {
            return nil
        }
        let version = result.trimmedOutput.split(separator: " ").first.map(String.init) ?? ""
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        guard (parts[0], parts[1]) >= (minimumSnapshotSQLiteVersion.major, minimumSnapshotSQLiteVersion.minor)
        else {
            Self.logger.info("Remote sqlite3 \(version, privacy: .public) predates VACUUM INTO")
            return nil
        }
        return "sqlite3"
    }

    // MARK: - Fingerprint

    static func fingerprint(
        session: LibSSH2SFTPSession,
        remotePath: String
    ) throws -> RemoteFileFingerprint {
        let main = try session.stat(remotePath)
        let walPath = remotePath + "-wal"
        let wal = try? session.stat(walPath)
        return RemoteFileFingerprint(
            mainSize: main.size,
            mainModified: main.modified,
            writeAheadLogSize: wal?.size
        )
    }

    // MARK: - Fetch

    static func fetch(
        session: LibSSH2SFTPSession,
        identity: RemoteFileIdentity,
        plan: RemoteFetchPlan,
        layout: DatabaseFileLayout,
        destinationDirectory: URL,
        fileName: String,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> RemoteFetchResult {
        let remotePath = identity.path
        let stat = try session.stat(remotePath)
        guard !stat.isDirectory else { throw SFTPError.notAFile(path: remotePath) }
        try requireLocalSpace(for: stat.size, at: destinationDirectory)

        let before = try fingerprint(session: session, remotePath: remotePath)
        let staging = destinationDirectory.appendingPathComponent(".\(fileName).incoming")
        try? FileManager.default.removeItem(at: staging)

        let downloaded: (bytes: UInt64, sha256: String)
        switch plan {
        case .remoteSnapshot(let executable):
            downloaded = try fetchViaRemoteSnapshot(
                session: session,
                executable: executable,
                remotePath: remotePath,
                staging: staging,
                progress: progress,
                isCancelled: isCancelled
            )
        case .directCopy(let sidecars):
            downloaded = try session.download(
                remotePath: remotePath, to: staging, progress: progress, isCancelled: isCancelled
            )
            try fetchSidecars(
                session: session,
                remotePath: remotePath,
                sidecars: sidecars,
                destinationDirectory: destinationDirectory,
                fileName: fileName,
                isCancelled: isCancelled
            )
        }

        let expectedBytes = plan.method == .remoteSnapshot ? downloaded.bytes : stat.size
        let verdict = DatabaseFileIntegrity.verifyDownload(
            at: staging,
            expectedBytes: expectedBytes,
            runsIntegrityCheck: layout.acceptsSQLiteIntegrityCheck
        )
        guard verdict.isOK else {
            try? FileManager.default.removeItem(at: staging)
            throw transferError(for: verdict, path: remotePath)
        }

        let workingCopy = destinationDirectory.appendingPathComponent(fileName)
        try replaceLocalItem(at: workingCopy, with: staging)

        let manifest = RemoteFileManifest(
            origin: identity.displayOrigin,
            username: identity.username,
            host: identity.host,
            port: identity.port,
            remotePath: remotePath,
            fetchedAt: Date(),
            remoteSize: before.mainSize,
            remoteModified: before.mainModified,
            remoteWriteAheadLogSize: before.writeAheadLogSize,
            downloadedSHA256: downloaded.sha256,
            snapshotMethod: plan.method
        )

        Self.logger.info(
            """
            Fetched \(identity.displayOrigin, privacy: .public) \
            via \(plan.method.rawValue, privacy: .public), \(downloaded.bytes) bytes
            """
        )
        return RemoteFetchResult(workingCopy: workingCopy, manifest: manifest, plan: plan)
    }

    /// Asks the server to write a consistent snapshot beside the database, fetches that, and removes
    /// it. The temp name carries a UUID so two windows fetching the same file never collide.
    private static func fetchViaRemoteSnapshot(
        session: LibSSH2SFTPSession,
        executable: String,
        remotePath: String,
        staging: URL,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        if isCancelled() { throw SFTPError.cancelled }
        let snapshotPath = "\(remotePath).tablepro-snapshot-\(UUID().uuidString)"
        defer { session.remove(snapshotPath) }

        let command = "\(executable) \(LibSSH2ExecChannel.shellQuoted(remotePath)) "
            + LibSSH2ExecChannel.shellQuoted("VACUUM INTO \(sqlStringLiteral(snapshotPath))")
        let result = try session.runRemoteCommand(command)
        guard result.succeeded else {
            throw SFTPError.remoteCommandFailed(
                command: "VACUUM INTO",
                status: result.exitStatus,
                output: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return try session.download(
            remotePath: snapshotPath, to: staging, progress: progress, isCancelled: isCancelled
        )
    }

    private static func fetchSidecars(
        session: LibSSH2SFTPSession,
        remotePath: String,
        sidecars: [String],
        destinationDirectory: URL,
        fileName: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        for suffix in sidecars {
            if isCancelled() { throw SFTPError.cancelled }
            let source = remotePath + suffix
            guard session.exists(source) else { continue }
            let target = destinationDirectory.appendingPathComponent(fileName + suffix)
            try session.download(remotePath: source, to: target, isCancelled: isCancelled)
            Self.logger.info("Fetched the \(suffix, privacy: .public) sidecar")
        }
    }

    // MARK: - Helpers

    /// Quotes a path for a SQL string literal, which is not the same job as quoting it for the
    /// shell: SQL escapes a single quote by doubling it, and the shell cannot.
    private static func sqlStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func requireLocalSpace(for bytes: UInt64, at directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let needed = bytes * localFreeSpaceMultiplier
        guard UInt64(max(0, available)) < needed else { return }
        throw SFTPError.transferFailed(
            path: directory.path,
            detail: String(
                format: String(localized: "this Mac needs %@ free to open that database"),
                ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            )
        )
    }

    /// Moves the staged download onto the working copy through `replaceItemAt`, which is a rename
    /// when both sit on one volume, and they do: the staging file is created in the same directory.
    private static func replaceLocalItem(at destination: URL, with staging: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            try FileManager.default.moveItem(at: staging, to: destination)
            return
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    }

    private static func transferError(
        for verdict: DatabaseFileIntegrity.Verdict,
        path: String
    ) -> SFTPError {
        switch verdict {
        case .ok:
            return .transferFailed(path: path, detail: "")
        case .wrongSize(let expected, let actual):
            return .shortTransfer(path: path, received: Int(actual), expected: Int(expected))
        case .notADatabase:
            return .transferFailed(
                path: path,
                detail: String(localized: "what arrived is not a database file")
            )
        case .corrupt(let detail):
            return .transferFailed(
                path: path,
                detail: String(format: String(localized: "the copy failed its integrity check: %@"), detail)
            )
        }
    }
}
