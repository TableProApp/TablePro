//
//  ConnectionFormCoordinator+SafeMode.swift
//  TablePro
//

import Foundation

@MainActor
extension ConnectionFormCoordinator {
    var safeModeFloor: SafeModeFloor? {
        SafeModeFloor.resolve(
            isEngineReadOnly: services.pluginManager.isEngineReadOnly(for: network.type),
            opensRemoteDatabaseFile: transport == .remoteFile,
            managedMinimum: ManagedPolicyResolver.minimumSafeModeLevel(policy: ManagedPolicyReader.shared)
        )
    }

    /// The level the connection will run at, which is what the form shows. Picking the level
    /// already shown keeps the user's saved choice, which comes back once the floor lifts.
    var effectiveSafeModeLevel: SafeModeLevel {
        get { safeModeFloor?.raising(customization.safeModeLevel) ?? customization.safeModeLevel }
        set {
            guard newValue != effectiveSafeModeLevel else { return }
            customization.safeModeLevel = newValue
        }
    }
}
