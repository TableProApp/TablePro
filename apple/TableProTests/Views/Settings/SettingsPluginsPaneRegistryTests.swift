import AppKit
@testable import TablePro
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    // Selecting a pane persists it in the shared defaults until the case puts it back.
    @MainActor
    struct SettingsPluginsPaneRegistryTests {
        @Test("The Plugins pane fetches the manifest through the registry client the window was given")
        func pluginsPaneUsesTheInjectedRegistryClient() async throws {
            let defaults = AppStorageEnvironment.shared.defaults
            let paneKey = PreferenceKeys.selectedSettingsPane.name
            let storedPane = defaults.string(forKey: paneKey)
            let registry = try OfflineRegistry()
            let split = SettingsSplitViewController(registryClient: registry.client)
            let window = NSWindow(contentViewController: split)
            window.isReleasedWhenClosed = false
            window.setContentSize(SettingsSplitViewController.minimumContentSize)
            defer {
                window.contentViewController = nil
                window.orderOut(nil)
                if let storedPane {
                    defaults.set(storedPane, forKey: paneKey)
                } else {
                    defaults.removeObject(forKey: paneKey)
                }
            }

            split.navigate(to: .plugins)
            window.layoutIfNeeded()
            try await waitUntil { registry.client.isManifestCurrent }

            #expect(registry.requestCount == 1)
        }
    }
}
