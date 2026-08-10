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
            .task { wireUp() }
    }

    private func wireUp() {
        WindowOpener.shared.setWelcomePresenter { openWindow(id: SceneId.welcome) }
        WindowOpener.shared.setConnectionFormPresenter { request in
            openWindow(id: SceneId.connectionForm, value: request)
        }
        WindowOpener.shared.setSettingsPresenter { openSettings() }
    }
}
