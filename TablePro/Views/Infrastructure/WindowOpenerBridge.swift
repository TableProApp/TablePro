//
//  WindowOpenerBridge.swift
//  TablePro
//

import SwiftUI

internal struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { wireUp() }
    }

    private func wireUp() {
        WindowOpener.shared.wire(
            openWelcome: { openWindow(id: SceneId.welcome) },
            openConnectionForm: { id in openWindow(id: SceneId.connectionForm, value: id) },
            openIntegrationsActivity: { openWindow(id: SceneId.integrationsActivity) }
        )
    }
}
