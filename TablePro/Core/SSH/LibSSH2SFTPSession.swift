//
//  LibSSH2SFTPSession.swift
//  TablePro
//

import CLibSSH2
import CryptoKit
import Foundation
import os

/// What a remote file looked like at a moment in time.
///
/// SFTP v3 reports mtime in whole seconds and carries no checksum, and a writer that renames a
/// temp file into place hands its own mtime to the target, so this cannot prove a file is
/// unchanged. It is enough to prove one *has* changed, which is the direction that matters before
/// overwriting someone else's data.
struct SFTPFileStat: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let isDirectory: Bool

    /// The permission bits, for a write-back that has to put them back on the replacement.
    let permissions: Int
}

/// An authenticated SSH session carrying the SFTP subsystem and nothing else.
///
/// A sibling of `LibSSH2Tunnel` rather than a mode of it: a tunnel owns a listening socket and an
/// accept loop, both meaningless here. Both types build their session through
/// `LibSSH2TunnelFactory.buildAuthenticatedChain`, so SFTP inherits password, public key, agent,
/// keyboard-interactive, jump hosts, TOTP and `~/.ssh/config` resolution without restating any of
/// it, and tears down through the same `cleanupChain`.
///
/// libssh2 is not thread-safe per session, so every call runs on one serial queue.
final class LibSSH2SFTPSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SFTP")

    /// Measured against OpenSSH 10.3: 32 KiB requests give ~94 MiB/s up and ~320 MiB/s down on
    /// loopback while keeping each `libssh2_sftp_read` inside one SFTP packet.
    private static let chunkSize = 32 * 1_024

    private let chain: LibSSH2TunnelFactory.AuthenticatedChain
    private let sftp: OpaquePointer
    private let queue: DispatchQueue
    private let host: String
    private let closed = OSAllocatedUnfairLock(initialState: false)

    private init(
        chain: LibSSH2TunnelFactory.AuthenticatedChain,
        sftp: OpaquePointer,
        queue: DispatchQueue,
        host: String
    ) {
        self.chain = chain
        self.sftp = sftp
        self.queue = queue
        self.host = host
    }

    // MARK: - Lifecycle

    static func open(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        label: String
    ) async throws -> LibSSH2SFTPSession {
        let chain = try await LibSSH2TunnelFactory.buildAuthenticatedChain(
            config: config,
            credentials: credentials,
            queueLabel: "com.TablePro.sftp.hop.\(label)"
        )

        let queue = DispatchQueue(label: "com.TablePro.sftp.\(label)", qos: .utility)
        let sftp: OpaquePointer? = queue.sync {
            libssh2_session_set_blocking(chain.session, 1)
            return libssh2_sftp_init(chain.session)
        }

        guard let sftp else {
            LibSSH2TunnelFactory.cleanupChain(chain, reason: "SFTP unavailable")
            throw SFTPError.subsystemUnavailable(config.host)
        }

        Self.logger.info("SFTP subsystem open on \(config.host, privacy: .public)")
        return LibSSH2SFTPSession(chain: chain, sftp: sftp, queue: queue, host: config.host)
    }

    func close() {
        let wasOpen = closed.withLock { isClosed -> Bool in
            let was = !isClosed
            isClosed = true
            return was
        }
        guard wasOpen else { return }

        queue.sync { libssh2_sftp_shutdown(sftp) }
        LibSSH2TunnelFactory.cleanupChain(chain, reason: "SFTP session closed")
        Self.logger.info("SFTP session closed for \(self.host, privacy: .public)")
    }

    // MARK: - Metadata

    func stat(_ path: String) throws -> SFTPFileStat {
        try run { sftp in
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            let rc = libssh2_sftp_stat_ex(
                sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_STAT, &attrs
            )
            guard rc == 0 else {
                throw SFTPError.fromStatus(
                    libssh2_sftp_last_error(sftp), path: path, detail: "stat failed (\(rc))"
                )
            }
            return SFTPFileStat(
                size: attrs.filesize,
                modified: Date(timeIntervalSince1970: TimeInterval(attrs.mtime)),
                isDirectory: (attrs.permissions & UInt(S_IFMT)) == UInt(S_IFDIR),
                permissions: Int(attrs.permissions & 0o7777)
            )
        }
    }

    /// Whether a path exists, without the caller having to distinguish "absent" from "failed".
    func exists(_ path: String) -> Bool {
        (try? stat(path)) != nil
    }

    /// Bytes free on the volume holding `path`, or nil when the server does not answer statvfs.
    func freeSpace(atPath path: String) -> UInt64? {
        try? run { sftp in
            var vfs = LIBSSH2_SFTP_STATVFS()
            let rc = libssh2_sftp_statvfs(sftp, path, path.utf8.count, &vfs)
            guard rc == 0 else {
                throw SFTPError.transferFailed(path: path, detail: "statvfs unsupported")
            }
            return vfs.f_bsize * vfs.f_bavail
        }
    }

    /// Resolves a path the way the server sees it, which is the only way to expand a leading `~`
    /// or a relative path: SFTP itself does no expansion and rejects a literal `~/x` outright.
    func realPath(_ path: String) throws -> String {
        try run { sftp in
            var buffer = [Int8](repeating: 0, count: 4_096)
            let rc = libssh2_sftp_symlink_ex(
                sftp, path, UInt32(path.utf8.count), &buffer, UInt32(buffer.count - 1),
                LIBSSH2_SFTP_REALPATH
            )
            guard rc > 0 else {
                throw SFTPError.fromStatus(
                    libssh2_sftp_last_error(sftp), path: path, detail: "realpath failed (\(rc))"
                )
            }
            return String(cString: buffer)
        }
    }

    /// Turns whatever the user typed into the path this server sees.
    ///
    /// SFTP performs no expansion of its own: a literal `~/db.sqlite` fails to open, and a relative
    /// path is taken against the login directory. Both are things people type into a path field, so
    /// both resolve here through the server's own realpath rather than by guessing at a home.
    func resolvedPath(_ path: String) throws -> String {
        let expanded: String
        if path.hasPrefix("~") || !path.hasPrefix("/") {
            let home = try realPath(".")
            let relative = path.hasPrefix("~/") ? String(path.dropFirst(2)) : (path == "~" ? "" : path)
            expanded = relative.isEmpty ? home : "\(home)/\(relative)"
        } else {
            expanded = path
        }

        // Canonicalize through the server so a symlink resolves to the file it names. Sidecars sit
        // beside the real database, not beside the link, and a rename onto the link would replace
        // the link itself and leave the database untouched. A path that does not exist yet has no
        // canonical form, and the expanded one is the right answer for it.
        return (try? realPath(expanded)) ?? expanded
    }

    struct DirectoryEntry: Sendable, Identifiable, Hashable {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        var id: String { name }
    }

    func listDirectory(_ path: String) throws -> [DirectoryEntry] {
        try run { sftp in
            guard let handle = libssh2_sftp_open_ex(
                sftp, path, UInt32(path.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR
            ) else {
                throw SFTPError.fromStatus(
                    libssh2_sftp_last_error(sftp), path: path, detail: "cannot open directory"
                )
            }
            defer { libssh2_sftp_close_handle(handle) }

            var entries: [DirectoryEntry] = []
            var name = [Int8](repeating: 0, count: 512)
            var longEntry = [Int8](repeating: 0, count: 512)
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            while libssh2_sftp_readdir_ex(
                handle, &name, name.count, &longEntry, longEntry.count, &attrs
            ) > 0 {
                let entryName = String(cString: name)
                if entryName != "." && entryName != ".." {
                    entries.append(DirectoryEntry(
                        name: entryName,
                        isDirectory: (attrs.permissions & UInt(S_IFMT)) == UInt(S_IFDIR),
                        size: attrs.filesize
                    ))
                }
                name = [Int8](repeating: 0, count: 512)
                longEntry = [Int8](repeating: 0, count: 512)
            }
            return entries.sorted { lhs, rhs in
                lhs.isDirectory == rhs.isDirectory
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.isDirectory
            }
        }
    }

    // MARK: - Download

    /// Downloads `remotePath` to `localURL`, returning the SHA-256 of what actually arrived.
    ///
    /// The hash is taken on the way past rather than by re-reading, so verifying a transfer costs
    /// nothing. `progress` reports bytes received against the size reported by stat.
    @discardableResult
    func download(
        remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> (bytes: UInt64, sha256: String) {
        let expected = try stat(remotePath)
        guard !expected.isDirectory else { throw SFTPError.notAFile(path: remotePath) }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: localURL.path) else {
            throw SFTPError.transferFailed(
                path: localURL.path, detail: "cannot write the local working copy"
            )
        }
        defer { try? output.close() }

        return try run { sftp in
            guard let handle = libssh2_sftp_open_ex(
                sftp, remotePath, UInt32(remotePath.utf8.count),
                UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE
            ) else {
                throw SFTPError.fromStatus(
                    libssh2_sftp_last_error(sftp), path: remotePath, detail: "cannot open for reading"
                )
            }
            defer { libssh2_sftp_close_handle(handle) }

            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
            var received: UInt64 = 0

            while true {
                if isCancelled() { throw SFTPError.cancelled }
                let read = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return libssh2_sftp_read(handle, base.assumingMemoryBound(to: CChar.self), raw.count)
                }
                if read == 0 { break }
                guard read > 0 else {
                    throw SFTPError.transferFailed(
                        path: remotePath, detail: "read failed after \(received) bytes (\(read))"
                    )
                }
                let slice = buffer.prefix(read)
                hasher.update(data: slice)
                try output.write(contentsOf: slice)
                received += UInt64(read)
                progress?(received, expected.size)
            }

            guard received == expected.size else {
                throw SFTPError.shortTransfer(
                    path: remotePath, received: Int(received), expected: Int(expected.size)
                )
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (received, digest)
        }
    }

    /// Deletes a path, reporting nothing.
    ///
    /// The only thing this removes is a snapshot the app asked the server to write for it, on the
    /// cleanup path where the fetch has already succeeded or already failed. A user's database is
    /// never passed here: a remote-file connection is read-only and nothing else writes to the
    /// server at all.
    func remove(_ path: String) {
        _ = try? run { sftp in
            libssh2_sftp_unlink_ex(sftp, path, UInt32(path.utf8.count))
        }
    }

    // MARK: - Remote commands

    /// Runs a command on the same authenticated session the transfers use.
    ///
    /// One session carries both because the alternative is a second full authentication, which for
    /// a bastion with two-factor means a second prompt. Both go through the same serial queue, so
    /// they never overlap inside libssh2.
    func runRemoteCommand(_ command: String) throws -> RemoteCommandResult {
        guard !closed.withLock({ $0 }) else {
            throw SFTPError.transferFailed(path: host, detail: "the SFTP session is closed")
        }
        return try LibSSH2ExecChannel.run(command, session: chain.session, queue: queue)
    }

    // MARK: - Private

    private func run<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard !closed.withLock({ $0 }) else {
            throw SFTPError.transferFailed(path: host, detail: "the SFTP session is closed")
        }
        return try queue.sync { try body(sftp) }
    }
}
