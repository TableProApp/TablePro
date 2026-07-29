//
//  WelcomeViewModel+ConnectionCreation.swift
//  TablePro
//

import Foundation

extension WelcomeViewModel {
    func handle(_ request: WelcomeRequest) {
        switch request {
        case .chooseDatabaseType(let payload):
            databaseTypeChooser = payload
        case .exportConnections:
            guard !connections.isEmpty else { return }
            exportConnections(connections)
        case .importConnections:
            importConnectionsFromFile()
        case .importFromApp:
            importConnectionsFromApp()
        case .importFromURL:
            urlImportPresented = true
        case .openProjectFolder:
            openProjectFolder()
        }
    }

    func selectDatabaseType(_ type: DatabaseType, for payload: DatabaseTypeChooserPayload) {
        databaseTypeChooser = nil
        guard services.pluginManager.isDriverInstalled(for: type) else {
            pendingInstallPayload = payload
            pendingInstallType = type
            return
        }
        applySelectedDatabaseType(type, payload: payload)
    }

    func completePendingInstall(for type: DatabaseType) {
        guard let payload = pendingInstallPayload else { return }
        pendingInstallPayload = nil
        applySelectedDatabaseType(type, payload: payload)
    }

    func presentURLImport() {
        databaseTypeChooser = nil
        urlImportPresented = true
    }

    private func applySelectedDatabaseType(_ type: DatabaseType, payload: DatabaseTypeChooserPayload) {
        PendingNewConnectionType.shared.set(type)
        payload.onSelected(type)
    }
}
