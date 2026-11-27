//
//  WelcomeViewModel+ConnectionCreation.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProImport

extension WelcomeViewModel {
    func handle(_ request: WelcomeRequest) {
        switch request {
        case .chooseDatabaseType(let payload):
            databaseTypeChooser = payload
        case .exportConnections:
            let listed = scopedLibrary.connections
            guard !listed.isEmpty else { return }
            exportConnections(listed)
        case .importConnections:
            importConnectionsFromFile()
        case .importFromApp:
            importConnectionsFromApp()
        case .importFromAWS:
            importConnectionsFromAWS()
        case .importFromURL:
            urlImportPresented = true
        case .openProjectFolder:
            openProjectFolder()
        case .importHandoff(let handoff):
            handOff(handoff)
        case .newProject:
            activeSheet = .newProject
        case .manageProjects:
            activeSheet = .manageProjects
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
        WindowOpener.shared.openStagedConnectionForm()
    }

    func presentURLImport() {
        databaseTypeChooser = nil
        urlImportPresented = true
    }

    private func applySelectedDatabaseType(_ type: DatabaseType, payload: DatabaseTypeChooserPayload) {
        payload.onSelected(type)
    }
}
