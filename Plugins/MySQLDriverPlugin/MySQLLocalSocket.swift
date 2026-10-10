//
//  MySQLLocalSocket.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated internal enum MySQLLocalSocket {
    static let fieldKey = "localSocketPath"
    static let defaultPath = "/tmp/mysql.sock"
    /// Darwin's `sun_path` is 104 bytes and the last one is the terminating NUL.
    static let maximumPathBytes = 103

    enum PathIssue: Equatable, Sendable {
        case notAbsolute
        case tooLong(bytes: Int)

        var message: String {
            switch self {
            case .notAbsolute:
                return String(localized: "The socket path must start with /.")
            case .tooLong(let bytes):
                return String(
                    format: String(localized: "The socket path is %d bytes. macOS allows %d at most."),
                    bytes,
                    MySQLLocalSocket.maximumPathBytes
                )
            }
        }
    }

    static func path(in fields: [String: String]) -> String? {
        guard let path = fields[fieldKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    static func issue(for path: String) -> PathIssue? {
        guard path.hasPrefix("/") else { return .notAbsolute }
        let bytes = path.utf8.count
        guard bytes <= maximumPathBytes else { return .tooLong(bytes: bytes) }
        return nil
    }

    /// The mysql client's rule: Preferred leaves a socket unencrypted, Required and stricter encrypt it.
    static func attemptsTLS(_ mode: SSLMode, overSocket: Bool) -> Bool {
        switch mode {
        case .disabled:
            return false
        case .preferred:
            return !overSocket
        case .required, .verifyCa, .verifyIdentity:
            return true
        }
    }
}
