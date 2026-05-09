import Foundation
import os
import TableProModels

// MARK: - Error Category

enum AppErrorCategory: Sendable {
    case network
    case auth
    case config
    case query
    case ssh
    case system
}

// MARK: - App Error

struct AppError: LocalizedError, Sendable {
    let category: AppErrorCategory
    let title: String
    let message: String
    let recovery: String?
    let underlying: Error?

    var errorDescription: String? { message }
}

// MARK: - Error Context

struct ErrorContext: Sendable {
    let operation: String
    let databaseType: DatabaseType?
    let host: String?
    let sshEnabled: Bool

    init(operation: String, databaseType: DatabaseType? = nil, host: String? = nil, sshEnabled: Bool = false) {
        self.operation = operation
        self.databaseType = databaseType
        self.host = host
        self.sshEnabled = sshEnabled
    }
}

// MARK: - Error Classifier

enum ErrorClassifier {
    private static let logger = Logger(subsystem: "com.TablePro", category: "Error")

    static func classify(_ error: Error, context: ErrorContext) -> AppError {
        let message = error.localizedDescription.lowercased()

        logger.error("[\(context.operation)] \(error.localizedDescription, privacy: .public)")

        if error is LocalNetworkPermissionError {
            return AppError(
                category: .network,
                title: String(localized: "Local Network Access Required"),
                message: error.localizedDescription,
                recovery: String(localized: "Open Settings > Privacy & Security > Local Network and turn TablePro on, then try again."),
                underlying: error
            )
        }

        let host = context.host ?? ""
        let mayUseLocalNetwork = context.sshEnabled || LocalNetworkPermission.isLocalNetworkHost(host)
        let timedOut = message.contains("timeout") || message.contains("timed out") || message.contains("operation timed out") || message.contains("system error: 60")
        if mayUseLocalNetwork && timedOut {
            return network(error, context: context)
        }

        if message.contains("ssh") || message.contains("tunnel") || message.contains("handshake") {
            return ssh(error, context: context)
        }

        // Auth errors
        if message.contains("authentication") || message.contains("password") ||
            message.contains("denied") || message.contains("credential") ||
            message.contains("permission") || message.contains("access denied") ||
            message.contains("fe_sendauth")
        {
            return auth(error, context: context)
        }

        // Network errors
        if message.contains("timeout") || message.contains("timed out") ||
            message.contains("connection refused") || message.contains("unreachable") ||
            message.contains("network") || message.contains("could not connect") ||
            message.contains("no route") || message.contains("connection reset")
        {
            return network(error, context: context)
        }

        // Query errors
        if message.contains("syntax") || message.contains("no such table") ||
            message.contains("does not exist") || message.contains("constraint") ||
            message.contains("duplicate") || message.contains("violation") ||
            message.contains("unknown column")
        {
            return query(error, context: context)
        }

        // Config errors
        if message.contains("not found") || message.contains("unsupported") ||
            message.contains("invalid") || message.contains("no driver")
        {
            return config(error, context: context)
        }

        // Default
        return AppError(
            category: .system,
            title: "Error",
            message: error.localizedDescription,
            recovery: nil,
            underlying: error
        )
    }

    private static func ssh(_ error: Error, context: ErrorContext) -> AppError {
        let msg = error.localizedDescription
        let recovery: String

        if msg.lowercased().contains("authentication") || msg.lowercased().contains("key") {
            recovery = String(localized: "Check your SSH username, password, or private key.")
        } else if msg.lowercased().contains("handshake") {
            recovery = String(localized: "The SSH server may be unreachable or running a different protocol.")
        } else if msg.lowercased().contains("channel") {
            recovery = String(localized: "The SSH tunnel connected but could not forward to the database port.")
        } else {
            recovery = String(localized: "Check your SSH host, port, and credentials.")
        }

        return AppError(
            category: .ssh,
            title: String(localized: "SSH Tunnel Failed"),
            message: msg,
            recovery: recovery,
            underlying: error
        )
    }

    private static func auth(_ error: Error, context: ErrorContext) -> AppError {
        let dbName = context.databaseType?.rawValue ?? "Database"
        return AppError(
            category: .auth,
            title: String(localized: "Authentication Failed"),
            message: error.localizedDescription,
            recovery: String(format: String(localized: "Check your %@ username and password."), dbName),
            underlying: error
        )
    }

    private static func network(_ error: Error, context: ErrorContext) -> AppError {
        let msg = error.localizedDescription
        let lowered = msg.lowercased()
        let recovery: String

        let isTimeout = lowered.contains("timeout") || lowered.contains("timed out") || lowered.contains("operation timed out") || lowered.contains("system error: 60")
        let host = context.host ?? ""
        let mayUseLocalNetwork = context.sshEnabled || LocalNetworkPermission.isLocalNetworkHost(host)

        if isTimeout && mayUseLocalNetwork {
            recovery = String(localized: "Local Network access may be blocked. Open Settings > Privacy & Security > Local Network and turn TablePro on.")
        } else if isTimeout {
            recovery = String(localized: "The server is not responding. Check the host and port.")
        } else if lowered.contains("refused") {
            recovery = String(localized: "Connection refused. The server may not be running or the port is incorrect.")
        } else {
            recovery = String(localized: "Check your network connection and server availability.")
        }

        return AppError(
            category: .network,
            title: String(localized: "Connection Failed"),
            message: msg,
            recovery: recovery,
            underlying: error
        )
    }

    private static func query(_ error: Error, context: ErrorContext) -> AppError {
        let msg = error.localizedDescription
        let recovery: String

        if msg.lowercased().contains("syntax") {
            recovery = String(localized: "Check your SQL syntax.")
        } else if msg.lowercased().contains("constraint") || msg.lowercased().contains("duplicate") {
            recovery = String(localized: "The operation violates a database constraint.")
        } else if msg.lowercased().contains("no such table") || msg.lowercased().contains("does not exist") {
            recovery = String(localized: "The table or column does not exist.")
        } else {
            recovery = String(localized: "Check your query and try again.")
        }

        return AppError(
            category: .query,
            title: String(localized: "Query Error"),
            message: msg,
            recovery: recovery,
            underlying: error
        )
    }

    private static func config(_ error: Error, context: ErrorContext) -> AppError {
        AppError(
            category: .config,
            title: String(localized: "Configuration Error"),
            message: error.localizedDescription,
            recovery: String(localized: "Check your connection settings."),
            underlying: error
        )
    }
}
