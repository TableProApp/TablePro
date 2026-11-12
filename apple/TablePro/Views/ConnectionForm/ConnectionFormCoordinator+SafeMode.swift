//
//  ConnectionFormCoordinator+SafeMode.swift
//  TablePro
//

import Foundation
import TableProSSHConfig

@MainActor
extension ConnectionFormCoordinator {
    var safeModeFloor: SafeModeFloor? {
        SafeModeFloor.resolve(
            isEngineReadOnly: services.pluginManager.isEngineReadOnly(for: network.type),
            opensRemoteDatabaseFile: transport == .remoteFile && ssh.state.remoteFileAccess == .readOnlyCopy,
            managedMinimum: ManagedPolicyResolver.minimumSafeModeLevel(policy: ManagedPolicyReader.shared)
        )
    }

    // Picking the level already shown keeps the saved choice, which comes back once the floor lifts.
    var effectiveSafeModeLevel: SafeModeLevel {
        get { safeModeFloor?.raising(customization.safeModeLevel) ?? customization.safeModeLevel }
        set {
            guard newValue != effectiveSafeModeLevel else { return }
            customization.safeModeLevel = newValue
        }
    }

    var isManualCommitAvailable: Bool { ManualCommit.isAvailable(for: network.type) }

    // Off where the engine can't hold, since a stored Manual Commit runs as automatic there.
    var effectiveManualCommit: Bool {
        get { isManualCommitAvailable && customization.commitMode == .manual }
        set {
            guard isManualCommitAvailable else { return }
            customization.commitMode = newValue ? .manual : .automatic
        }
    }
}
