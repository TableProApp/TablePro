//
//  LibSSH2ExecChannel.swift
//  TablePro
//

import CLibSSH2
import Foundation
import os

/// What a remote command left behind.
struct RemoteCommandResult: Sendable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String

    /// The name of the signal that killed the command, when one did. A process killed by a signal
    /// carries no exit status, so `libssh2_channel_get_exit_status` reports the stored `0`; without
    /// this, an OOM-killed or interrupted `VACUUM INTO` would read as success and its half-written
    /// snapshot would be adopted.
    let exitSignal: String?

    var succeeded: Bool { exitStatus == 0 && exitSignal == nil }

    var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs one command on the SSH server and collects what it printed.
///
/// The app needs this for exactly two things: asking whether the remote has a `sqlite3` new enough
/// to take a consistent snapshot of a database another process is writing, and then asking it to
/// take one. Both are reads. Nothing here composes a command from user input, and the one argument
/// that varies (a path) is single-quoted by `shellQuoted`.
///
/// Some servers refuse exec entirely, which a chrooted SFTP-only account does by design. That is an
/// ordinary answer rather than a failure: the caller falls back to copying the file directly and
/// tells the user why that is weaker.
enum LibSSH2ExecChannel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHExec")

    private static let readChunk = 16 * 1_024

    /// Wraps a string as one shell word. Single quotes suppress every expansion the shell performs,
    /// and the only character they cannot carry is a single quote, which is closed, escaped and
    /// reopened. A remote path is the only thing the app ever passes through here.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func run(
        _ command: String,
        session: OpaquePointer,
        queue: DispatchQueue
    ) throws -> RemoteCommandResult {
        try queue.sync {
            guard let channel = libssh2_channel_open_ex(
                session, "session", 7, 2 * 1_024 * 1_024, 32_768, nil, 0
            ) else {
                throw SFTPError.remoteCommandFailed(
                    command: command, status: -1, output: "the server refused a session channel"
                )
            }
            defer { libssh2_channel_free(channel) }

            guard libssh2_channel_process_startup(
                channel, "exec", 4, command, UInt32(command.utf8.count)
            ) == 0 else {
                throw SFTPError.remoteCommandFailed(
                    command: command, status: -1, output: "the server refused to run commands"
                )
            }

            let out = drain(channel: channel, streamId: 0)
            let err = drain(channel: channel, streamId: sshExtendedDataStderr)
            libssh2_channel_close(channel)
            let status = libssh2_channel_get_exit_status(channel)
            let signal = exitSignal(channel: channel, session: session)

            Self.logger.debug(
                "remote command exited \(status, privacy: .public) signal \(signal ?? "none", privacy: .public): \(command, privacy: .public)"
            )
            return RemoteCommandResult(
                exitStatus: status, standardOutput: out, standardError: err, exitSignal: signal
            )
        }
    }

    /// The signal name libssh2 recorded for the channel's process, or nil when it exited normally.
    /// libssh2 allocates the string, so it is freed here.
    private static func exitSignal(channel: OpaquePointer, session: OpaquePointer) -> String? {
        var signalPtr: UnsafeMutablePointer<CChar>?
        var signalLen = 0
        libssh2_channel_get_exit_signal(channel, &signalPtr, &signalLen, nil, nil, nil, nil)
        defer { if let signalPtr { libssh2_free(session, signalPtr) } }
        guard let signalPtr, signalLen > 0 else { return nil }
        let name = String(cString: signalPtr)
        return name.isEmpty ? nil : name
    }

    private static func drain(channel: OpaquePointer, streamId: Int32) -> String {
        var collected = Data()
        var buffer = [CChar](repeating: 0, count: readChunk)
        while true {
            let read = libssh2_channel_read_ex(channel, streamId, &buffer, buffer.count)
            if read <= 0 { break }
            collected.append(contentsOf: buffer.prefix(read).map { UInt8(bitPattern: $0) })
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }
}

/// libssh2 does not export the stderr stream id, so it is named here rather than passed as 1.
private let sshExtendedDataStderr: Int32 = 1
