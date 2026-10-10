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
        case hiddenCharacter
        case tooLong(bytes: Int)

        var message: String {
            switch self {
            case .notAbsolute:
                return String(localized: "The socket path must start with /.")
            case .hiddenCharacter:
                return String(localized: "The socket path contains a control or invisible character.")
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

    // connect(2) stops at a NUL, so the driver would dial a different path than the one shown, and a
    // control or format character hides part of the path wherever it is shown.
    static func issue(for path: String) -> PathIssue? {
        guard path.hasPrefix("/") else { return .notAbsolute }
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format]
        guard !path.unicodeScalars.contains(where: { hidden.contains($0.properties.generalCategory) }) else {
            return .hiddenCharacter
        }
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
