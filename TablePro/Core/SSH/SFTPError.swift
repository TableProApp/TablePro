//
//  SFTPError.swift
//  TablePro
//

import CLibSSH2
import Foundation

enum SFTPError: LocalizedError, Equatable {
    case subsystemUnavailable(String)
    case noSuchFile(path: String)
    case permissionDenied(path: String)
    case notAFile(path: String)
    case transferFailed(path: String, detail: String)
    case shortTransfer(path: String, received: Int, expected: Int)
    case remoteCommandFailed(command: String, status: Int32, output: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .subsystemUnavailable(let host):
            return String(
                format: String(localized: "%@ accepted the SSH connection but refused the SFTP subsystem."),
                host
            )
        case .noSuchFile(let path):
            return String(format: String(localized: "No file at %@ on the server."), path)
        case .permissionDenied(let path):
            return String(format: String(localized: "The SSH account cannot read %@."), path)
        case .notAFile(let path):
            return String(format: String(localized: "%@ is a directory, not a database file."), path)
        case .transferFailed(let path, let detail):
            return String(format: String(localized: "Transfer of %@ failed: %@"), path, detail)
        case .shortTransfer(let path, let received, let expected):
            return String(
                format: String(localized: "Only %1$d of %2$d bytes of %3$@ arrived."),
                received, expected, path
            )
        case .remoteCommandFailed(let command, let status, let output):
            return String(
                format: String(localized: "`%1$@` exited with status %2$d on the server: %3$@"),
                command, status, output
            )
        case .cancelled:
            return String(localized: "The transfer was cancelled.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .subsystemUnavailable:
            return String(localized: "Check that the SSH server enables the sftp subsystem for this account.")
        case .noSuchFile:
            return String(localized: "Check the remote path, including its capitalisation.")
        case .permissionDenied:
            return String(localized: "Grant the SSH account read access, or connect as a user that already has it.")
        default:
            return nil
        }
    }

    /// Maps an SFTP status code to the case that names it, so a failed call reports the server's
    /// own reason instead of a generic transfer failure.
    static func fromStatus(_ status: UInt, path: String, detail: @autoclosure () -> String) -> SFTPError {
        switch status {
        case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH):
            return .noSuchFile(path: path)
        case UInt(LIBSSH2_FX_PERMISSION_DENIED), UInt(LIBSSH2_FX_WRITE_PROTECT):
            return .permissionDenied(path: path)
        default:
            return .transferFailed(path: path, detail: detail())
        }
    }
}
