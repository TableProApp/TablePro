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

    // The level the gate decides with. A run reads it here too, so the statement carries the level it was approved under.
    @MainActor
    static func effectiveSafeModeLevel(for connectionId: UUID, in manager: DatabaseManager? = nil) -> SafeModeLevel {
        let connectionLevel: SafeModeLevel
        switch (manager ?? .shared).connectionState(connectionId) {
        case .live(_, let session):
            connectionLevel = session.safeModeLevel
        case .stored(let connection):
            connectionLevel = connection.safeModeLevel
        case .unknown:
            connectionLevel = .silent
        }
        return ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: connectionLevel,
            policy: ManagedPolicyReader.shared
        )
    }

    @MainActor
    static func runsAtReadOnly(_ connectionId: UUID, in manager: DatabaseManager? = nil) -> Bool {
        effectiveSafeModeLevel(for: connectionId, in: manager).blocksAllWrites
    }

    @MainActor
    static func readOnlyFunctionPolicy(
        connectionId: UUID,
        databaseType: DatabaseType,
        in manager: DatabaseManager? = nil
    ) -> ReadOnlyFunctionPolicy {
        let state = (manager ?? .shared).connectionState(connectionId)
        let (liveDriver, connection): (DatabaseDriver?, DatabaseConnection?) = switch state {
        case .live(let driver, let session): (driver, session.connection)
        case .stored(let stored): (nil, stored)
        case .unknown: (nil, nil)
        }
        let floor: SafeModeLevel? = if let connection {
            AgentModeSafeModeFloor.effectiveFloor(for: connection)?.level
        } else {
            ManagedPolicyResolver.minimumSafeModeLevel(policy: ManagedPolicyReader.shared)
        }
        return ReadOnlyFunctionPolicy(
            functionsCanWrite: liveDriver?.enforcesReadOnlyMode != true
                && PluginMetadataRegistry.queryFunctionsCanWrite.contains(databaseType),
            floor: floor
        )
    }

    static let shared: ExecutionGate = DefaultExecutionGate(
        confirming: AlertOperationConfirming(),
        authenticating: BiometricOperationAuthenticating(),
        safeModeLevelResolver: { connectionId in
            await effectiveSafeModeLevel(for: connectionId)
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
        },
        readOnlyFunctionPolicyResolver: { connectionId, databaseType in
            await readOnlyFunctionPolicy(connectionId: connectionId, databaseType: databaseType)
        }
    )
}
