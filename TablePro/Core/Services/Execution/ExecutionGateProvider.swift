//
//  ExecutionGateProvider.swift
//  TablePro
//

import Foundation

internal enum ExecutionGateProvider {
    /// A driver that declares no read-only mode gets every statement treated as a write, unless the
    /// classifier can prove reads on its engine. The declaration stays the fallback for an engine the
    /// classifier does not know.
    static func forcesWrite(_ databaseType: DatabaseType, supportsReadOnlyMode: Bool) -> Bool {
        !supportsReadOnlyMode && !QueryClassifier.enginesWithProvenReads.contains(databaseType)
    }

    static let shared: ExecutionGate = DefaultExecutionGate(
        confirming: AlertOperationConfirming(),
        authenticating: BiometricOperationAuthenticating(),
        safeModeLevelResolver: { connectionId in
            let connectionLevel: SafeModeLevel = await MainActor.run {
                switch DatabaseManager.shared.connectionState(connectionId) {
                case .live(_, let session):
                    return session.safeModeLevel
                case .stored(let connection):
                    return connection.safeModeLevel
                case .unknown:
                    return .silent
                }
            }
            return ManagedPolicyResolver.effectiveSafeModeLevel(
                connectionLevel: connectionLevel,
                policy: ManagedPolicyReader.shared
            )
        },
        forcesWriteResolver: { databaseType in
            let supportsReadOnlyMode = await MainActor.run {
                PluginManager.shared.supportsReadOnlyMode(for: databaseType)
            }
            return forcesWrite(databaseType, supportsReadOnlyMode: supportsReadOnlyMode)
        },
        connectionNameResolver: { connectionId in
            await MainActor.run {
                switch DatabaseManager.shared.connectionState(connectionId) {
                case .live(_, let session):
                    return session.connection.name
                case .stored(let connection):
                    return connection.name
                case .unknown:
                    return nil
                }
            }
        }
    )
}
