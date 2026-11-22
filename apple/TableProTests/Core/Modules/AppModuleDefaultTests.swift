import Foundation
@testable import TablePro
import Testing

// A tool that was core before it became a module stays on for a Mac that ran an earlier build and starts off on a new one.
@MainActor
struct AppModuleDefaultTests {
    private func launch(_ suite: EphemeralDefaults) -> AppModuleSettings {
        let storage = AppSettingsStorage(userDefaults: suite.defaults)
        AppModule.recordDefaults(in: suite.defaults, isExistingInstall: storage.hasLaunchedBefore())
        storage.migrateStartupBehaviorToReopenLastIfNeeded()
        return AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
    }

    private func existingInstall() throws -> EphemeralDefaults {
        let suite = try EphemeralDefaults()
        AppSettingsStorage(userDefaults: suite.defaults).migrateStartupBehaviorToReopenLastIfNeeded()
        return suite
    }

    @Test("A new install starts with Compare & Sync off, and the next launch keeps it off")
    func newInstallStartsOff() throws {
        let suite = try EphemeralDefaults()

        #expect(!launch(suite).isEnabled(.compareSync))
        #expect(!launch(suite).isEnabled(.compareSync))
        #expect(AppModule.enabledModules(in: suite.defaults).isEmpty)
    }

    @Test("A Mac that ran an earlier build keeps Compare & Sync on, and only modules that were core")
    func existingInstallKeepsItOn() throws {
        let suite = try existingInstall()
        let settings = launch(suite)

        #expect(settings.isEnabled(.compareSync))
        #expect(!settings.isEnabled(.routineDebugger))
        #expect(!settings.isEnabled(.liveMessages))
        #expect(launch(suite).isEnabled(.compareSync))
    }

    @Test("Finishing onboarding on an older build also marks an existing install")
    func onboardingMarksAnExistingInstall() throws {
        let suite = try EphemeralDefaults()
        AppSettingsStorage(userDefaults: suite.defaults).markWelcomeSheetSeen()

        #expect(launch(suite).isEnabled(.compareSync))
    }

    @Test("The default is recorded once; a later launch never changes it")
    func defaultIsRecordedOnce() throws {
        let suite = try EphemeralDefaults()
        AppModule.recordDefaults(in: suite.defaults, isExistingInstall: false)
        AppModule.recordDefaults(in: suite.defaults, isExistingInstall: true)

        #expect(!AppModule.compareSync.defaultEnabled(in: suite.defaults))
    }

    @Test("Recording writes only the default keys: the on/off keys an older build reads stay unset")
    func recordingLeavesTheOnOffKeys() throws {
        let suite = try existingInstall()
        _ = launch(suite)

        for module in AppModule.allCases {
            #expect(suite.defaults.object(forKey: module.defaultsKey) == nil, "\(module.rawValue)")
        }
        #expect(suite.defaults.object(forKey: AppModule.routineDebugger.recordedDefaultKey) == nil)
        #expect(suite.defaults.object(forKey: AppModule.liveMessages.recordedDefaultKey) == nil)
    }

    @Test("Turning the module off on an existing install survives a relaunch")
    func userChoiceWins() throws {
        let suite = try existingInstall()
        launch(suite).setEnabled(false, for: .compareSync)

        #expect(!launch(suite).isEnabled(.compareSync))
    }

    // Reset applies to the host's menu bar, so each case ends with the module off, as the host has it.
    @Test("Reset All Settings turns Compare & Sync back on for a Mac that had it before")
    func resetReturnsAnExistingInstallToOn() throws {
        let suite = try existingInstall()
        let settings = launch(suite)
        defer { AppModuleActivation.setEnabled(false, for: .compareSync, settings: settings) }
        settings.setEnabled(false, for: .compareSync)

        AppModuleActivation.resetToDefaults(settings: settings)

        #expect(settings.isEnabled(.compareSync))
    }

    @Test("Reset All Settings turns Compare & Sync back off on a new install")
    func resetReturnsANewInstallToOff() throws {
        let suite = try EphemeralDefaults()
        let settings = launch(suite)
        settings.setEnabled(true, for: .compareSync)

        AppModuleActivation.resetToDefaults(settings: settings)

        #expect(!settings.isEnabled(.compareSync))
    }
}
