//
//  WindowOpenerBridge.swift
//  TablePro
//

import Combine
import SwiftUI

internal struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task { wireUp() }
    }

    private func wireUp() {
        WindowOpener.shared.wire(
            openWelcome: { openWindow(id: SceneId.welcome) },
            openConnectionForm: { id in openWindow(id: SceneId.connectionForm, value: id) },
            openIntegrationsActivity: { openWindow(id: SceneId.integrationsActivity) },
            openSettings: { openSettings() },
            presentTypeChooser: { initialType, onSelected in
                let payload = DatabaseTypeChooserPayload(
                    initialType: initialType,
                    onSelected: onSelected
                )
                AppCommands.shared.presentDatabaseTypeChooser.send(payload)
            }
        )
    }
}

internal final class DatabaseTypeChooserPayload {
    let initialType: DatabaseType?
    let onSelected: (DatabaseType) -> Void

    init(initialType: DatabaseType?, onSelected: @escaping (DatabaseType) -> Void) {
        self.initialType = initialType
        self.onSelected = onSelected
    }
}
