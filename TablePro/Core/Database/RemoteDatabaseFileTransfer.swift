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

    /// The log's modification time. A commit followed by a checkpoint can leave the main file and
    /// the log's size unchanged and move only this: measured on Linux with the default
    /// `journal_size_limit = -1`, three inserts took the row count up while `(mainSize, mainModified,
    /// walSize)` all stayed put and only the log's mtime advanced. Without it a busy database reads
    /// as untouched and the stale copy is reused.
    var writeAheadLogModified: Date?

    func differs(from other: RemoteFileFingerprint) -> Bool {
        mainSize != other.mainSize
            || mainModified != other.mainModified
            || writeAheadLogSize != other.writeAheadLogSize
            || writeAheadLogModified != other.writeAheadLogModified
    }
}

struct RemoteFetchResult: Sendable {
    let generation: RemoteFileGeneration
    let manifest: RemoteFileManifest
    let plan: RemoteFetchPlan
    let fetchedSidecars: Set<String>

    var workingCopy: URL { generation.workingCopy }
}

internal protocol RemoteFileSource {
    func exists(_ path: String, deadline: ConnectionDeadline) throws -> Bool

    @discardableResult
    func download(
        remotePath: String,
        to localURL: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String)
}

internal protocol RemoteSnapshotSession: RemoteFileSource {
    func runRemoteCommand(_ command: String, deadline: ConnectionDeadline) throws -> RemoteCommandResult
    func remove(_ path: String, deadline: ConnectionDeadline)
}

extension LibSSH2SFTPSession: RemoteSnapshotSession {}

/// Copies a database file from a server into a local working copy.
///
/// Every rule here comes from something that was measured rather than assumed. The three that
/// decide whether this is safe:
///
/// - A download and every data-carrying sidecar are written into one hidden generation and promoted
///   together only after the main file's byte count and integrity pass. SFTP writes a file front to
///   back, so a transfer cut short by a dropped session or a cancelled connect leaves an intact
///   header and a plausible prefix; `sqlite3_open` on that will happily report success.
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

    /// Past the longest supported connection budget, so the fallback cannot delete a snapshot from
    /// under a valid download, but still finite when the caller disappears.
    static let snapshotCleanupDelaySeconds = ConnectionTimeoutPolicy.connectTimeoutRange.upperBound + 300

    // MARK: - Planning

    static func plan(
        session: LibSSH2SFTPSession,
        remotePath: String,
        layout: DatabaseFileLayout,
        deadline: ConnectionDeadline
    ) throws -> RemoteFetchPlan {
        let presentSidecars = try layout.dataCarryingSidecarSuffixes
            .filter { try session.exists(remotePath + $0, deadline: deadline) }

        guard layout.supportsRemoteSnapshot,
              let executable = try snapshotExecutable(on: session, deadline: deadline) else {
            return .directCopy(sidecars: presentSidecars)
        }
        return .remoteSnapshot(executable: executable)
    }

    /// Finds a remote `sqlite3` new enough to take a consistent snapshot.
    ///
    /// A server may refuse exec entirely, which a chrooted SFTP-only account does by design. That is
    /// an ordinary answer, not a failure: the caller copies directly and says so.
    private static func snapshotExecutable(
        on session: LibSSH2SFTPSession,
        deadline: ConnectionDeadline
    ) throws -> String? {
        let result: RemoteCommandResult
        do {
            result = try session.runRemoteCommand("sqlite3 --version", deadline: deadline)
        } catch let timeout as ConnectionTimeoutError {
            throw timeout
        } catch SFTPError.cancelled {
            throw SFTPError.cancelled
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard result.succeeded else { return nil }
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
        remotePath: String,
        deadline: ConnectionDeadline
    ) throws -> RemoteFileFingerprint {
        let main = try session.stat(remotePath, deadline: deadline)
        let walPath = remotePath + "-wal"
        let wal: SFTPFileStat?
        do {
            wal = try session.stat(walPath, deadline: deadline)
        } catch let timeout as ConnectionTimeoutError {
            throw timeout
        } catch SFTPError.cancelled {
            throw SFTPError.cancelled
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            wal = nil
        }
        return RemoteFileFingerprint(
            mainSize: main.size,
            mainModified: main.modified,
            writeAheadLogSize: wal?.size,
            writeAheadLogModified: wal?.modified
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
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> RemoteFetchResult {
        let remotePath = identity.path
        let timeoutEndpoint = ConnectionTimeoutEndpoint.remoteFile("\(identity.host):\(identity.port)")
        try deadline.check(endpoint: timeoutEndpoint)
        let stat = try session.stat(remotePath, deadline: deadline)
        guard !stat.isDirectory else { throw SFTPError.notAFile(path: remotePath) }
        try requireLocalSpace(for: stat.size, at: destinationDirectory)

        let before = try fingerprint(session: session, remotePath: remotePath, deadline: deadline)
        let generation = try RemoteDatabaseFileStore.prepareGeneration(
            in: destinationDirectory,
            fileName: fileName
        )
        do {
            let downloaded: (bytes: UInt64, sha256: String)
            let fetchedSidecars: Set<String>
            switch plan {
            case .remoteSnapshot(let executable):
                downloaded = try fetchViaRemoteSnapshot(
                    session: session,
                    executable: executable,
                    remotePath: remotePath,
                    staging: generation.workingCopy,
                    deadline: deadline,
                    progress: progress,
                    isCancelled: isCancelled
                )
                fetchedSidecars = []
            case .directCopy(let sidecars):
                downloaded = try session.download(
                    remotePath: remotePath,
                    to: generation.workingCopy,
                    deadline: deadline,
                    progress: progress,
                    isCancelled: isCancelled
                )
                fetchedSidecars = try fetchSidecars(
                    from: session,
                    remotePath: remotePath,
                    sidecars: sidecars,
                    stagingDirectory: generation.directory,
                    fileName: fileName,
                    deadline: deadline,
                    isCancelled: isCancelled
                )
            }
            try deadline.check(endpoint: timeoutEndpoint)

            let expectedBytes = plan.method == .remoteSnapshot ? downloaded.bytes : stat.size
            let verdict = try DatabaseFileIntegrity.verifyDownload(
                at: generation.workingCopy,
                expectedBytes: expectedBytes,
                runsIntegrityCheck: layout.acceptsSQLiteIntegrityCheck,
                deadline: deadline,
                timeoutEndpoint: timeoutEndpoint,
                isCancelled: isCancelled
            )
            guard verdict.isOK else {
                throw transferError(for: verdict, path: remotePath)
            }
            if isCancelled() { throw SFTPError.cancelled }
            try deadline.check(endpoint: timeoutEndpoint)

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
                remoteWriteAheadLogModified: before.writeAheadLogModified,
                downloadedSHA256: downloaded.sha256,
                snapshotMethod: plan.method
            )
            try RemoteDatabaseFileStore.writeManifest(manifest, to: generation.directory)

            Self.logger.info(
                """
                Fetched \(identity.displayOrigin, privacy: .public) \
                via \(plan.method.rawValue, privacy: .public), \(downloaded.bytes) bytes
                """
            )
            return RemoteFetchResult(
                generation: generation,
                manifest: manifest,
                plan: plan,
                fetchedSidecars: fetchedSidecars
            )
        } catch {
            RemoteDatabaseFileStore.discardUnpublishedGeneration(generation)
            throw error
        }
    }

    /// Asks the server to write a consistent snapshot beside the database, fetches that, and removes
    /// it. The temp name carries a UUID so two windows fetching the same file never collide.
    static func fetchViaRemoteSnapshot(
        session: some RemoteSnapshotSession,
        executable: String,
        remotePath: String,
        staging: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool,
        cleanupDelaySeconds: Int = snapshotCleanupDelaySeconds
    ) throws -> (bytes: UInt64, sha256: String) {
        if isCancelled() { throw SFTPError.cancelled }
        let snapshotPath = "\(remotePath).tablepro-snapshot-\(UUID().uuidString)"
        defer { session.remove(snapshotPath, deadline: deadline) }

        let command = remoteSnapshotCommand(
            executable: executable,
            remotePath: remotePath,
            snapshotPath: snapshotPath,
            cleanupDelaySeconds: cleanupDelaySeconds
        )
        let result = try session.runRemoteCommand(command, deadline: deadline)
        guard result.succeeded else {
            throw SFTPError.remoteCommandFailed(
                command: "VACUUM INTO",
                status: result.exitStatus,
                output: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return try session.download(
            remotePath: snapshotPath,
            to: staging,
            deadline: deadline,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// Schedules deletion on the server while the connection deadline is still live. The immediate
    /// `defer` above remains the common path; this detached fallback owns no SSH channel descriptors
    /// and survives the session being interrupted after a timed-out download.
    static func remoteSnapshotCommand(
        executable: String,
        remotePath: String,
        snapshotPath: String,
        cleanupDelaySeconds: Int = snapshotCleanupDelaySeconds
    ) -> String {
        let quotedPath = LibSSH2ExecChannel.shellQuoted(remotePath)
        let vacuum = "\(executable) \(quotedPath) "
            + LibSSH2ExecChannel.shellQuoted("VACUUM INTO \(sqlStringLiteral(snapshotPath))")
        let delayedCleanup = "trap '' HUP; sleep \(cleanupDelaySeconds); rm -f -- "
            + LibSSH2ExecChannel.shellQuoted(snapshotPath)
        let quotedCleanup = LibSSH2ExecChannel.shellQuoted(delayedCleanup)
        return """
        umask 077
        if command -v nohup >/dev/null 2>&1; then
            nohup sh -c \(quotedCleanup) </dev/null >/dev/null 2>&1 &
        else
            (\(delayedCleanup)) </dev/null >/dev/null 2>&1 &
        fi
        :
        \(vacuum)
        """
    }

    static func fetchSidecars(
        from source: some RemoteFileSource,
        remotePath: String,
        sidecars: [String],
        stagingDirectory: URL,
        fileName: String,
        deadline: ConnectionDeadline,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Set<String> {
        var fetched: Set<String> = []
        for suffix in sidecars {
            if isCancelled() { throw SFTPError.cancelled }
            let remoteSidecar = remotePath + suffix
            guard try source.exists(remoteSidecar, deadline: deadline) else {
                Self.logger.info("The \(suffix, privacy: .public) sidecar was gone before it was fetched")
                continue
            }
            let target = stagingDirectory.appendingPathComponent(fileName + suffix)
            try source.download(
                remotePath: remoteSidecar,
                to: target,
                deadline: deadline,
                progress: nil,
                isCancelled: isCancelled
            )
            fetched.insert(suffix)
            Self.logger.info("Fetched the \(suffix, privacy: .public) sidecar")
        }
        return fetched
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
