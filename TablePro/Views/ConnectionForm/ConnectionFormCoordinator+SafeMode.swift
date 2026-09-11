//
//  ConnectionFormCoordinator+SafeMode.swift
//  TablePro
//

import Foundation

@MainActor
extension ConnectionFormCoordinator {
    var readOnlyEnforcement: ReadOnlyEnforcement? {
        ReadOnlyEnforcement.resolve(
            isEngineReadOnly: services.pluginManager.isEngineReadOnly(for: network.type),
            opensRemoteDatabaseFile: transport == .remoteFile
        )
    }
}
