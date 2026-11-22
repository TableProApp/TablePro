//
//  SettingsWindowTitleTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    // The sidebar window reads and writes the selected-pane default, so it nests here for serialized
    // access to that process-wide value.
    @MainActor
    struct SettingsWindowNavigationTests {
        @MainActor
        private final class Host {
            var windows: [NSWindow] = []
            let registry: OfflineRegistry
            let storedPane: String?

            init() throws {
                registry = try OfflineRegistry()
                storedPane = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
            }

            func makeSplit() -> (SettingsSplitViewController, NSWindow) {
                let split = SettingsSplitViewController(registryClient: registry.client)
                let window = NSWindow(contentViewController: split)
                window.isReleasedWhenClosed = false
                windows.append(window)
                return (split, window)
            }

            func tearDown() async {
                for window in windows {
                    window.contentViewController = nil
                    window.orderOut(nil)
                }
                windows = []
                await registry.settle()
                let key = PreferenceKeys.selectedSettingsPane.name
                if let storedPane {
                    AppStorageEnvironment.shared.defaults.set(storedPane, forKey: key)
                } else {
                    AppStorageEnvironment.shared.defaults.removeObject(forKey: key)
                }
            }
        }

        @Test("The sidebar order is every pane exactly once")
        func everyPaneIsReachableExactlyOnce() {
            #expect(SettingsNavigation.orderedPanes.count == SettingsPane.allCases.count)
            #expect(Set(SettingsNavigation.orderedPanes) == Set(SettingsPane.allCases))
        }

        @Test("The window title follows the selected pane")
        func windowTitleFollowsTheSelectedPane() async throws {
            let host = try Host()
            let (split, window) = host.makeSplit()

            for pane in SettingsPane.allCases {
                split.navigate(to: pane)
                #expect(window.title == pane.title)
            }
            await host.tearDown()
        }

        @Test("A fresh controller opens on the persisted pane")
        func freshControllerOpensOnThePersistedPane() async throws {
            let host = try Host()
            AppStorageEnvironment.shared.defaults.set(
                SettingsPane.keyboard.rawValue,
                forKey: PreferenceKeys.selectedSettingsPane.name
            )
            let (_, window) = host.makeSplit()
            #expect(window.title == SettingsPane.keyboard.title)
            await host.tearDown()
        }

        @Test("A stored MCP pane restores the pane titled MCP")
        func storedMCPPaneRestoresTheMCPTitle() async throws {
            let host = try Host()
            AppStorageEnvironment.shared.defaults.set("mcp", forKey: PreferenceKeys.selectedSettingsPane.name)
            let (_, window) = host.makeSplit()
            #expect(window.title == "MCP")
            await host.tearDown()
        }

        // The rawValue is the persisted pane and the deep-link id, so it outlives any title.
        @Test("Pane identifiers survive title changes")
        func paneIdentifiersSurviveTitleChanges() {
            #expect(SettingsPane.mcp.rawValue == "mcp")
            #expect(SettingsPane.account.rawValue == "account")
            #expect(SettingsPane.account.urlIdentifier == "license")
        }

        @Test("Navigating with no pane reads the stored pane rather than staying put")
        func navigatingWithNoPaneReadsTheStoredPane() async throws {
            let host = try Host()
            let (split, window) = host.makeSplit()
            split.navigate(to: .plugins)
            #expect(window.title == SettingsPane.plugins.title)

            AppStorageEnvironment.shared.defaults.set(
                SettingsPane.editor.rawValue,
                forKey: PreferenceKeys.selectedSettingsPane.name
            )
            split.navigate(to: nil)
            #expect(window.title == SettingsPane.editor.title)
            await host.tearDown()
        }

        // A deep link / openSettings jump must not overwrite the user's last-used pane.
        @Test("A programmatic jump does not clobber the persisted pane")
        func programmaticJumpDoesNotClobberThePersistedPane() async throws {
            let host = try Host()
            let key = PreferenceKeys.selectedSettingsPane.name
            AppStorageEnvironment.shared.defaults.set(SettingsPane.editor.rawValue, forKey: key)
            let (split, _) = host.makeSplit()

            split.navigate(to: .ai)
            #expect(AppStorageEnvironment.shared.defaults.string(forKey: key) == SettingsPane.editor.rawValue)

            // A user click, by contrast, persists.
            split.model.userSelect(.mcp)
            #expect(AppStorageEnvironment.shared.defaults.string(forKey: key) == SettingsPane.mcp.rawValue)
            await host.tearDown()
        }

        @Test("The window refuses to shrink below the sidebar plus detail minimum")
        func theWindowRefusesToShrinkBelowTheMinimum() async throws {
            let host = try Host()
            let controller = SettingsWindowController(registryClient: host.registry.client)
            let window = try #require(controller.window, "The controller must build a window")
            window.isReleasedWhenClosed = false
            host.windows.append(window)
            #expect(window.contentMinSize == SettingsSplitViewController.minimumContentSize)
            await host.tearDown()
        }

        @Test("present() builds the settings window with its identifier")
        func presentBuildsTheSettingsWindow() async throws {
            let host = try Host()
            AppStorageEnvironment.shared.defaults.set(
                SettingsPane.general.rawValue,
                forKey: PreferenceKeys.selectedSettingsPane.name
            )
            let controller = SettingsWindowController()
            let window = try #require(controller.window, "Cmd-comma and settings links present this controller")
            window.isReleasedWhenClosed = false
            host.windows.append(window)
            #expect(window.identifier?.rawValue == WindowIdentifier.settings)
            await host.tearDown()
        }
    }
}
