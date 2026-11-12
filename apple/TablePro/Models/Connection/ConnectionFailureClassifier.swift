//
//  ConnectionFailureClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ConnectionFailureClassifier {
    internal enum ReconnectVerdict: Equatable, Sendable {
        case stop(ConnectionFailureInfo)
        case retry(ConnectionFailureInfo?)
    }

    internal static func reconnectVerdict(for error: SSLHandshakeError) -> ReconnectVerdict {
        switch error {
        case .serverRejectedPlaintext, .serverRequiresPlaintext, .clientCertRequired,
             .clientKeyPassphraseRequired, .clientKeyPassphraseIncorrect, .clientKeyInvalid:
            return .stop(info(for: error))
        case .untrustedCertificate, .hostnameMismatch:
            return .retry(info(for: error))
        case .cipherMismatch, .unknown:
            return .retry(nil)
        @unknown default:
            return .retry(nil)
        }
    }

    internal static func outcome(for error: Error, canEditConnection: Bool = true) -> ConnectionAttemptOutcome {
        if isUserCancelled(error) { return .cancelled }
        if let action = recoveryAction(for: error, canEditConnection: canEditConnection) {
            return .actionRequired(info(for: error), action)
        }
        return .failed(info(for: error))
    }

    internal static func endReason(for error: Error, canEditConnection: Bool) -> ConnectionEndReason? {
        switch outcome(for: error, canEditConnection: canEditConnection) {
        case .cancelled:
            return nil
        case .failed(let info):
            return .connectFailed(info, nil)
        case .actionRequired(let info, let action):
            return .connectFailed(info, action)
        }
    }

    internal static func recoveryAction(for error: Error, canEditConnection: Bool = true) -> ConnectionRecoveryAction? {
        if error is LoadableExtensionError || error is SSLModeNotSupportedError {
            return canEditConnection ? .editConnection : nil
        }
        if error is LocalNetworkAccessError {
            return .openLocalNetworkSettings
        }
        guard let pluginError = error as? PluginError else { return nil }
        switch pluginError {
        case .pluginNotInstalled:
            return .installPlugin
        case .pluginLoadFailed(let pluginId, _, _):
            return .openPluginSettings(pluginId: pluginId)
        case .pluginUpdateUnavailable:
            return .openPluginSettings(pluginId: nil)
        case .unknownDatabaseType:
            return canEditConnection ? .editConnection : nil
        default:
            return nil
        }
    }

    internal static func isUserCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TabRouterError.userCancelled = error { return true }
        if case PreConnectScriptConsentError.declined = error { return true }
        if case EnvVarReferenceConsentError.declined = error { return true }
        if case LocalCredentialConsentError.declined = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private static let invalidAuthorizationSQLState = "28000"
    private static let mysqlAccessDeniedErrorCode = 1_045

    internal static func isAuthenticationFailure(_ error: Error) -> Bool {
        if let pluginError = error as? any PluginDriverError {
            if pluginError.pluginSqlState == invalidAuthorizationSQLState {
                return true
            }
            if pluginError.pluginErrorCode == mysqlAccessDeniedErrorCode {
                return true
            }
            return messageIndicatesAuthenticationFailure(pluginError.pluginErrorMessage)
        }
        return messageIndicatesAuthenticationFailure(error.localizedDescription)
    }

    // SQL Server, Oracle, Redis, Cassandra and Snowflake word a refused login their own way.
    private static let refusedLoginPhrases = [
        "access denied", "authentication failed", "invalid credentials", "login failed for user", "ora-01017",
        "wrongpass", "password are incorrect", "incorrect username or password",
    ]

    // SQL Server says "Login failed for user" while it is upgrading or in single-user mode too, and connects again after.
    private static let passingLoginRefusals = ["script upgrade mode", "single user mode"]

    private static func messageIndicatesAuthenticationFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        guard !passingLoginRefusals.contains(where: { lowered.contains($0) }) else { return false }
        return refusedLoginPhrases.contains { lowered.contains($0) }
    }

    internal static func info(for error: Error) -> ConnectionFailureInfo {
        if error is SSLHandshakeError {
            return ConnectionFailureInfo(message: SSLHandshakeError.formatted(error))
        }
        if let refusal = error as? LocalNetworkAccessError {
            return ConnectionFailureInfo(
                title: String(localized: "Local Network Access Required"),
                message: refusal.errorDescription ?? "",
                recoverySuggestion: refusal.recoverySuggestion,
                details: info(for: refusal.underlying).lines.joined(separator: "\n")
            )
        }
        let nsError = error as NSError
        return ConnectionFailureInfo(
            message: error.localizedDescription,
            failureReason: nsError.localizedFailureReason,
            recoverySuggestion: nsError.localizedRecoverySuggestion
        )
    }
}
