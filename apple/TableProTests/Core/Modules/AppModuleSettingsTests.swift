import Foundation
@testable import TablePro
import Testing

@MainActor
struct AppModuleSettingsTests {
    @Test("Every module starts off on a Mac that never turned it on")
    func modulesStartOff() throws {
        let suite = try EphemeralDefaults()
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())

        for module in AppModule.allCases {
            #expect(module.defaultEnabled == false, "\(module.rawValue)")
            #expect(!settings.isEnabled(module), "\(module.rawValue)")
        }
        #expect(settings.enabledModules.isEmpty)
    }

    @Test("Turning a module on is stored in the defaults suite and read back by a new instance")
    func stateSurvivesRelaunch() throws {
        let suite = try EphemeralDefaults()
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())

        settings.setEnabled(true, for: .routineDebugger)

        #expect(suite.defaults.object(forKey: AppModule.routineDebugger.defaultsKey) as? Bool == true)
        let relaunched = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
        #expect(relaunched.isEnabled(.routineDebugger))
        #expect(AppModule.enabledModules(in: suite.defaults) == [.routineDebugger])

        settings.setEnabled(false, for: .routineDebugger)
        #expect(!AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
            .isEnabled(.routineDebugger))
    }

    @Test("Reset All Settings turns every module back to its default")
    func resetRestoresDefaults() throws {
        let suite = try EphemeralDefaults()
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
        settings.setEnabled(true, for: .routineDebugger)

        AppModuleActivation.resetToDefaults(settings: settings)

        for module in AppModule.allCases {
            #expect(settings.isEnabled(module) == module.defaultEnabled, "\(module.rawValue)")
        }
    }

    @Test("The change notification names the module and arrives after the new state is stored")
    func notificationFollowsTheStore() throws {
        let suite = try EphemeralDefaults()
        let center = NotificationCenter()
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: center)
        let defaults = suite.defaults
        var received: [(module: AppModule?, storedEnabled: Bool?)] = []
        let observer = center.addObserver(forName: .appModulesDidChange, object: nil, queue: nil) { note in
            received.append((
                note.object as? AppModule,
                defaults.object(forKey: AppModule.routineDebugger.defaultsKey) as? Bool
            ))
        }
        defer { center.removeObserver(observer) }

        settings.setEnabled(true, for: .routineDebugger)
        settings.setEnabled(false, for: .routineDebugger)

        let modules = received.map { $0.module }
        let stored = received.map { $0.storedEnabled }
        #expect(modules == [.routineDebugger, .routineDebugger])
        #expect(stored == [true, false])
    }

    @Test("Setting the state a module already has stores and posts nothing")
    func unchangedStateIsSilent() throws {
        let suite = try EphemeralDefaults()
        let center = NotificationCenter()
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: center)
        var posts = 0
        let observer = center.addObserver(forName: .appModulesDidChange, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(observer) }

        settings.setEnabled(false, for: .routineDebugger)

        #expect(posts == 0)
        #expect(suite.defaults.object(forKey: AppModule.routineDebugger.defaultsKey) == nil)
    }

    @Test("The key is namespaced and per module")
    func keysAreNamespaced() {
        let keys = AppModule.allCases.map { $0.defaultsKey }
        #expect(Set(keys).count == keys.count)
        for key in keys {
            #expect(key.hasPrefix("com.TablePro.modules."), "\(key)")
        }
    }

    @Test("Every module names itself and says what it does")
    func modulesDescribeThemselves() {
        for module in AppModule.allCases {
            #expect(!module.title.isEmpty)
            #expect(!module.summary.isEmpty)
        }
        #expect(AppModule.routineDebugger.rawValue == "routineDebugger")
    }
}
