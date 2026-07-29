//
//  ExecutionGateProvider.swift
//  TablePro
//

import Foundation

internal enum ExecutionGateProvider {
    static let shared: ExecutionGate = DefaultExecutionGate(
        confirming: AlertOperationConfirming(),
        authenticating: BiometricOperationAuthenticating(),
        safeModeLevelResolver: { connectionId in
            await MainActor.run {
                switch DatabaseManager.shared.connectionState(connectionId) {
                case .live(_, let session):
                    return session.safeModeLevel
                case .stored(let connection):
                    return connection.safeModeLevel
                case .unknown:
                    return .silent
                }
            }
        },
        forcesWriteResolver: { databaseType in
            await MainActor.run {
                !PluginManager.shared.supportsReadOnlyMode(for: databaseType)
            }
        }
    )
}
