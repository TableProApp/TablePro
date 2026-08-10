//
//  TableProApp.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI

/// The menu bar is not declared here. Every editor window is an AppKit `NSWindow`
/// rather than a SwiftUI `Scene`, so a `Commands`-authored menu could never ask the
/// key window's responder chain whether a command applies. `MainMenuBuilder` installs
/// the real menu from `AppDelegate.applicationDidFinishLaunching`, and every scene
/// declares `commandsRemoved()` so SwiftUI contributes nothing to it.
@main
struct TableProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @State private var updaterBridge = UpdaterBridge.shared

    init() {
        AppSettingsStorage.shared.migrateStartupBehaviorToReopenLastIfNeeded()
        AppSettingsStorage.shared.migrateJsonFieldHeightKeyIfNeeded()
        AIProviderRegistration.registerAll()

        Task {
            await QueryHistoryManager.shared.performStartupCleanup()
        }

        Task { @MainActor in
            let activeIds = Set(ConnectionStorage.shared.loadConnections().map(\.id))
            await SQLFavoriteManager.shared.pruneOrphaned(activeConnectionIds: activeIds)
        }
    }

    var body: some Scene {
        Window("Welcome to TablePro", id: SceneId.welcome) {
            WelcomeWindowView()
                .frame(width: 800, height: 480)
                .background(WindowOpenerBridge())
                .background(WindowChromeConfigurator(
                    restorable: false,
                    fullScreenable: false,
                    hideMiniaturizeButton: true,
                    hideZoomButton: true
                ))
                .environment(\.appServices, .live)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        WindowGroup("New Connection", id: SceneId.connectionForm, for: ConnectionFormRequest.self) { $request in
            ConnectionFormView(request: request)
                .background(WindowOpenerBridge())
                .background(WindowChromeConfigurator(restorable: false))
                .background(WindowSelfRaiser())
                .environment(\.appServices, .live)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 600)
        .commandsRemoved()


        Settings {
            SettingsView()
                .background(WindowOpenerBridge())
                .environment(updaterBridge)
                .environment(\.appServices, .live)
        }
    }
}
