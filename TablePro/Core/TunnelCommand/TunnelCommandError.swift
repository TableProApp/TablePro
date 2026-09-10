//
//  TunnelCommandError.swift
//  TablePro
//

import Foundation

enum TunnelCommandError: Error, LocalizedError, Equatable {
    case commandEmpty
    case missingLocalPortPlaceholder
    case unbalancedQuote
    case executableNotFound(String)
    case noAvailablePort
    case startupFailed(stderrTail: String)
    case readinessTimeout(stderrTail: String)
    case storeNotTrusted

    var errorDescription: String? {
        switch self {
        case .commandEmpty:
            return String(localized: "This connection has no tunnel command to run.")
        case .missingLocalPortPlaceholder:
            return String(
                format: String(localized: "The tunnel command must contain %@, where the local port goes."),
                TunnelCommandLine.localPortPlaceholder
            )
        case .unbalancedQuote:
            return String(localized: "The tunnel command has an unclosed quote.")
        case .executableNotFound(let name):
            return String(format: String(localized: "%@ was not found."), name)
        case .noAvailablePort:
            return String(localized: "No local port was free for the tunnel.")
        case .startupFailed(let tail):
            return tail.isEmpty
                ? String(localized: "The tunnel command exited before the port was open.")
                : String(
                    format: String(localized: "The tunnel command exited before the port was open:\n\n%@"),
                    tail
                )
        case .readinessTimeout(let tail):
            return tail.isEmpty
                ? String(localized: "The tunnel command did not open its local port in time.")
                : String(
                    format: String(localized: "The tunnel command did not open its local port in time:\n\n%@"),
                    tail
                )
        case .storeNotTrusted:
            return String(localized: """
                Your connections file was changed outside TablePro, so this connection's tunnel \
                command was not run. Open the connection and save it again to confirm the change.
                """)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .executableNotFound:
            return String(localized: """
                Give its full path in the connection. Apps launched from the Dock do not inherit \
                your shell's PATH.
                """)
        case .startupFailed, .readinessTimeout:
            return String(localized: "Run the command in Terminal to see what it reports.")
        default:
            return nil
        }
    }
}
