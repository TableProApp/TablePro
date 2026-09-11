//
//  ConnectionFailureClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ConnectionFailureClassifier {
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
        guard let pluginError = error as? PluginError else { return nil }
        switch pluginError {
        case .pluginNotInstalled:
            return .installPlugin
        case .pluginDisabled(let pluginId, _):
            return .enablePlugin(pluginId: pluginId)
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
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    internal static func info(for error: Error) -> ConnectionFailureInfo {
        if error is SSLHandshakeError {
            return ConnectionFailureInfo(message: SSLHandshakeError.formatted(error))
        }
        let nsError = error as NSError
        return ConnectionFailureInfo(
            message: error.localizedDescription,
            failureReason: nsError.localizedFailureReason,
            recoverySuggestion: nsError.localizedRecoverySuggestion
        )
    }
}
