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
    @State var vm = WelcomeViewModel()
    @FocusState private var focus: WelcomeFocusField?

    var body: some View {
        ZStack {
            if vm.showOnboarding {
                OnboardingContentView {
                    withMotion(.easeInOut(duration: 0.45)) {
                        vm.showOnboarding = false
                    }
                }
                .transition(.move(edge: .leading))
            } else {
                welcomeContent
                    .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            vm.setUp()
            focus = .connectionList
        }
        .modifier(WelcomePresentations(vm: vm) { focus = .connectionList })
    }

    private var welcomeContent: some View {
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
        .transition(.opacity)
    }
}

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}
