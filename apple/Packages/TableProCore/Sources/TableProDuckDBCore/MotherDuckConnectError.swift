import Foundation

public enum MotherDuckConnectError: Error, LocalizedError, Equatable, Sendable {
    case missingToken
    case invalidToken
    case invalidDatabase(name: String)
    case versionNotSupported(detail: String)
    case extensionUnavailable(detail: String)
    case tokenRejected(detail: String)
    case unreachable(detail: String)
    case noDatabase(name: String?)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return String(localized: "Access Token is required. Create one in MotherDuck's settings, under Access Tokens.")
        case .invalidToken:
            return String(localized: "The Access Token contains a control character. Copy it again from MotherDuck.")
        case .invalidDatabase(let name):
            return String(
                format: String(localized: "The database name %@ cannot contain ?, # or a control character."),
                name
            )
        case .versionNotSupported(let detail):
            return Self.reported(
                String(localized: """
                    MotherDuck does not accept the DuckDB version this plugin uses yet. The connection works once \
                    MotherDuck supports that version.
                    """),
                detail: detail
            )
        case .extensionUnavailable(let detail):
            return Self.reported(
                String(localized: """
                    DuckDB could not load its MotherDuck extension. The first connection downloads it from \
                    extensions.duckdb.org and ext.motherduck.com, and every connection checks api.motherduck.com.
                    """),
                detail: detail
            )
        case .tokenRejected(let detail):
            return Self.reported(
                String(localized: """
                    MotherDuck did not accept the Access Token. Check that it is complete and has not expired or \
                    been revoked.
                    """),
                detail: detail
            )
        case .unreachable(let detail):
            return Self.reported(
                String(localized: "TablePro could not reach MotherDuck. Check the network connection, then connect again."),
                detail: detail
            )
        case .noDatabase(let name):
            guard let name else {
                return String(localized: "MotherDuck attached no database for this Access Token.")
            }
            return String(format: String(localized: "MotherDuck attached no database named %@."), name)
        case .timedOut:
            return String(localized: "Connecting to MotherDuck timed out.")
        }
    }

    private static func reported(_ summary: String, detail: String) -> String {
        [summary, String(format: String(localized: "DuckDB reported: %@"), detail)].joined(separator: "\n\n")
    }
}

// Texts measured on DuckDB v1.5.6 and v2.0.1 with the extension MotherDuck served on 2026-11-23.
public enum MotherDuckConnectErrorClassifier {
    public static func classify(_ error: any Error) -> MotherDuckConnectError? {
        if let error = error as? MotherDuckConnectError { return error }
        switch error as? QuackConnectError {
        case .extensionNotInstalled(_, let detail), .extensionNotLoaded(_, let detail):
            return classify(message: detail) ?? .extensionUnavailable(detail: detail)
        default:
            return classify(message: error.localizedDescription)
        }
    }

    public static func classify(message: String) -> MotherDuckConnectError? {
        // First: the v2.0.0 extension refuses inside its init, which also reads as an extension that failed to load.
        if message.contains("is not yet supported") {
            return .versionNotSupported(detail: message)
        }
        if message.contains("Your request is not authenticated") {
            return .tokenRejected(detail: message)
        }
        // The timeout is the attempt's own deadline, handed to MotherDuck as motherduck_connection_timeout.
        if message.contains("Timed out connecting to MotherDuck") {
            return .timedOut
        }
        if message.contains("Could not connect to MotherDuck") {
            return .unreachable(detail: message)
        }
        let extensionTexts = [
            "Failed to download extension \"motherduck\"",
            "api.motherduck.com",
            "ext.motherduck.com",
            "was built specifically for DuckDB version",
            "MotherDuck extension is not available",
        ]
        if extensionTexts.contains(where: message.contains) {
            return .extensionUnavailable(detail: message)
        }
        return nil
    }
}
