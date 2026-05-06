//
//  WindowOpenerBridge.swift
//  TablePro
//

import SwiftUI

internal struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { wireUp() }
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
                NotificationCenter.default.post(
                    name: .presentDatabaseTypeChooser,
                    object: nil,
                    userInfo: [DatabaseTypeChooserPayload.userInfoKey: payload]
                )
            }
        )
    }
}

internal final class DatabaseTypeChooserPayload {
    static let userInfoKey = "DatabaseTypeChooserPayload"

    let initialType: DatabaseType?
    let onSelected: (DatabaseType) -> Void

    init(initialType: DatabaseType?, onSelected: @escaping (DatabaseType) -> Void) {
        self.initialType = initialType
        self.onSelected = onSelected
    }
}

internal extension Notification.Name {
    static let presentDatabaseTypeChooser = Notification.Name("com.TablePro.presentDatabaseTypeChooser")
}
