//
//  ConnectionFailureClassifier.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ConnectionFailureClassifier {
    internal static func outcome(for error: Error) -> ConnectionAttemptOutcome {
        if isUserCancelled(error) { return .cancelled }
        if case PluginError.pluginNotInstalled = error {
            return .pluginMissing(info(for: error))
        }
        return .failed(info(for: error))
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
