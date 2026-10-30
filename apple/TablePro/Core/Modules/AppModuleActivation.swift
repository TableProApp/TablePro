import AppKit

// The one writer of a module's state outside tests: the Extensions pane and Reset All Settings, both a click in TablePro.
@MainActor
enum AppModuleActivation {
    static func setEnabled(_ enabled: Bool, for module: AppModule, settings: AppModuleSettings = .shared) {
        guard settings.isEnabled(module) != enabled else { return }
        settings.setEnabled(enabled, for: module)
        if let bar = NSApp.mainMenu {
            MainMenuBuilder.applyModules(
                settings.enabledModules,
                keyboard: AppSettingsManager.shared.keyboard,
                to: bar,
                windowsMenu: NSApp.windowsMenu
            )
            MainMenuBuilder.syncKeyEquivalents()
        }
        MainWindowToolbar.applyModuleChange()
        if !enabled {
            stopWork(of: module)
        }
    }

    static func resetToDefaults(settings: AppModuleSettings = .shared) {
        for module in AppModule.allCases {
            setEnabled(module.defaultEnabled, for: module, settings: settings)
        }
    }

    private static func stopWork(of module: AppModule) {
        switch module {
        case .routineDebugger:
            Task { await RoutineDebugSessions.shared.stopAll() }
        }
    }
}
