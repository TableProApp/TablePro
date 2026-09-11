//
//  WelcomeWindowView.swift
//  TablePro
//

import SwiftUI

internal enum WelcomeFocusField: Hashable {
    case search
    case connectionList
}

struct WelcomeWindowView: View {
    let vm: WelcomeViewModel
    @FocusState private var focus: WelcomeFocusField?

    var body: some View {
        HStack(spacing: 0) {
            WelcomeActionsPanel(
                onActivateLicense: { vm.activeSheet = .activation },
                onCreateConnection: { WindowOpener.shared.openConnectionForm() },
                onImportFromURL: { vm.urlImportPresented = true },
                onImportFromApp: { vm.importConnectionsFromApp() },
                onOpenProjectFolder: { vm.openProjectFolder() },
                onImportConnectionsFile: { vm.importConnectionsFromFile() }
            )
            .frame(width: 240)
            .themeMaterial(.sidebar, .regularMaterial)

            Divider()

            WelcomeConnectionsPanel(vm: vm, focus: $focus)
        }
        .ignoresSafeArea()
        .onAppear {
            vm.setUp()
            focus = .connectionList
        }
        .modifier(WelcomePresentations(vm: vm) { focus = .connectionList })
    }
}

#Preview("Welcome Window") {
    WelcomeWindowView(vm: WelcomeViewModel())
        .frame(width: 800, height: 480)
}
