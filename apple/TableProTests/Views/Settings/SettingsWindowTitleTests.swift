import AppKit
@testable import TablePro
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    // The window reads and writes the last-used pane default, so it nests here for serialized access to it.
    @MainActor
    struct SettingsWindowNavigationTests {
        @MainActor
        private final class Host {
            var windows: [NSWindow] = []
            var controllers: [SettingsWindowController] = []
            let registry: OfflineRegistry
            let storedPane: String?

            init() throws {
                registry = try OfflineRegistry()
                storedPane = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
            }

            var persistedPane: String? {
                AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
            }

            func storePane(_ pane: SettingsPane) {
                AppStorageEnvironment.shared.defaults.set(pane.rawValue, forKey: PreferenceKeys.selectedSettingsPane.name)
            }

            func makeSplit() -> (SettingsSplitViewController, NSWindow) {
                let split = SettingsSplitViewController(registryClient: registry.client)
                let window = NSWindow(contentViewController: split)
                window.isReleasedWhenClosed = false
                windows.append(window)
                return (split, window)
            }

            func makeController() throws -> (SettingsWindowController, NSWindow) {
                let controller = SettingsWindowController(registryClient: registry.client)
                let window = try #require(controller.window, "The controller must build a window")
                window.isReleasedWhenClosed = false
                windows.append(window)
                controllers.append(controller)
                return (controller, window)
            }

            func tearDown() async {
                for controller in controllers {
                    controller.split.windowDidClose()
                }
                for window in windows {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet)
                    }
                    window.orderOut(nil)
                    window.contentViewController = nil
                }
                windows = []
                controllers = []
                await registry.settle()
                let key = PreferenceKeys.selectedSettingsPane.name
                if let storedPane {
                    AppStorageEnvironment.shared.defaults.set(storedPane, forKey: key)
                } else {
                    AppStorageEnvironment.shared.defaults.removeObject(forKey: key)
                }
            }
        }

        private static func toolbarIdentifiers(of window: NSWindow) -> [NSToolbarItem.Identifier] {
            window.toolbar?.items.map { $0.itemIdentifier } ?? []
        }

        @Test("The sidebar order is every pane exactly once")
        func everyPaneIsReachableExactlyOnce() {
            #expect(SettingsNavigation.orderedPanes.count == SettingsPane.allCases.count)
            #expect(Set(SettingsNavigation.orderedPanes) == Set(SettingsPane.allCases))
        }

        @Test("The window title follows every pane")
        func windowTitleFollowsEveryPane() async throws {
            let host = try Host()
            let (split, window) = host.makeSplit()

            for pane in SettingsPane.allCases {
                split.navigate(to: pane)
                #expect(window.title == pane.title)
            }
            await host.tearDown()
        }

        @Test("A pushed page titles the window, and Back returns the pane title")
        func pushedPageTitlesTheWindow() async throws {
            let host = try Host()
            let (split, window) = host.makeSplit()
            split.navigate(to: .appearance)

            #expect(split.model.push(.page(.manageThemes), in: .appearance))
            #expect(window.title == SettingsPage.manageThemes.title)

            split.goBack()
            #expect(window.title == SettingsPane.appearance.title)
            await host.tearDown()
        }

        @Test("A fresh window titles itself from the persisted pane")
        func freshControllerOpensOnThePersistedPane() async throws {
            let host = try Host()
            host.storePane(.keyboard)
            let (_, window) = host.makeSplit()
            #expect(window.title == SettingsPane.keyboard.title)
            await host.tearDown()
        }

        @Test("A stored MCP pane restores the window titled MCP")
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

        // Replaces "Navigating with no pane reads the stored pane": Cmd-, on an open window only brings it forward.
        @Test("No location leaves a visible window where it is, and opens a closed one on the last-used pane")
        func noLocationKeepsAVisibleWindowInPlace() async throws {
            let host = try Host()
            let (controller, window) = try host.makeController()
            #expect(controller.prepareToShow(.root(.plugins)))
            window.orderFront(nil)

            host.storePane(.editor)
            #expect(!controller.prepareToShow(nil))
            #expect(window.title == SettingsPane.plugins.title)

            window.orderOut(nil)
            #expect(controller.prepareToShow(nil))
            #expect(window.title == SettingsPane.editor.title)
            await host.tearDown()
        }

        @Test("A location never navigates under an attached sheet, and the menu items are off")
        func attachedSheetBlocksNavigation() async throws {
            let host = try Host()
            let (controller, window) = try host.makeController()
            controller.prepareToShow(.root(.general))
            window.orderFront(nil)
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheet.isReleasedWhenClosed = false
            controller.split.model.select(.data)
            window.beginSheet(sheet, completionHandler: nil)
            try await waitUntil { window.attachedSheet === sheet }

            #expect(!controller.prepareToShow(.root(.ai)))
            #expect(window.title == SettingsPane.data.title)
            let back = NSMenuItem(title: "Back", action: #selector(SettingsWindowController.navigateBack(_:)), keyEquivalent: "")
            #expect(!controller.validateMenuItem(back))

            window.endSheet(sheet)
            await host.tearDown()
        }

        @Test("A programmatic jump does not clobber the persisted pane")
        func programmaticJumpDoesNotClobberThePersistedPane() async throws {
            let host = try Host()
            host.storePane(.editor)
            let (split, _) = host.makeSplit()

            split.navigate(to: .ai)
            split.navigate(to: SettingsLocation(page: .slashCommands), recordsHistory: true)
            split.goBack()
            #expect(host.persistedPane == SettingsPane.editor.rawValue)

            // A pick in the sidebar, by contrast, persists.
            split.model.select(.mcp)
            #expect(host.persistedPane == SettingsPane.mcp.rawValue)
            await host.tearDown()
        }

        @Test("A sidebar click navigates, persists its pane and enables Back")
        func sidebarClickNavigatesAndPersists() async throws {
            let host = try Host()
            host.storePane(.general)
            let (split, window) = host.makeSplit()
            let row = try #require(split.sidebar.rows.firstIndex(of: .pane(.data)))

            split.sidebar.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

            #expect(window.title == SettingsPane.data.title)
            #expect(host.persistedPane == SettingsPane.data.rawValue)
            #expect(split.model.canGoBack)
            #expect(split.toolbarController.isBackEnabled)
            await host.tearDown()
        }

        @Test("A page found by the sidebar search opens with its pane selected and persisted")
        func searchResultOpensThePage() async throws {
            let host = try Host()
            host.storePane(.general)
            let (split, window) = host.makeSplit()
            let target = SettingsLocation(page: .sqlFormatting)

            split.sidebar.filter(by: "formatting")
            let row = try #require(split.sidebar.rows.firstIndex(of: .page(title: SettingsPage.sqlFormatting.title, location: target)))
            split.sidebar.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

            #expect(window.title == SettingsPage.sqlFormatting.title)
            #expect(split.model.location == target)
            #expect(host.persistedPane == SettingsPane.editor.rawValue)
            #expect(split.sidebar.tableView.selectedRow == row)

            split.sidebar.clearSearch()
            #expect(split.sidebar.tableView.selectedRow == split.sidebar.rows.firstIndex(of: .pane(.editor)))
            await host.tearDown()
        }

        // Updated on purpose: Back used to track only the pushed depth of one pane; it now follows
        // history across panes, as System Settings does.
        @Test("Back and Forward follow history across panes")
        func backEnablementTracksDepth() async throws {
            let host = try Host()
            host.storePane(.appearance)
            let (split, window) = host.makeSplit()
            #expect(!split.model.canGoBack)
            #expect(!split.toolbarController.isBackEnabled)

            split.model.select(.editor)
            #expect(split.toolbarController.isBackEnabled)
            #expect(!split.toolbarController.isForwardEnabled)

            split.goBack()
            #expect(window.title == SettingsPane.appearance.title)
            #expect(split.toolbarController.isForwardEnabled)

            split.goForward()
            #expect(window.title == SettingsPane.editor.title)
            #expect(!split.toolbarController.isForwardEnabled)
            await host.tearDown()
        }

        @Test("A deep link to a page in a closed window enables Back to the pane root")
        func deepLinkIntoAClosedWindowSeedsThePaneRoot() async throws {
            let host = try Host()
            let (controller, window) = try host.makeController()

            controller.prepareToShow(SettingsLocation(page: .sqlFormatting))
            #expect(window.title == SettingsPage.sqlFormatting.title)
            let back = NSMenuItem(title: "Back", action: #selector(SettingsWindowController.navigateBack(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(back))

            controller.navigateBack(nil)
            #expect(window.title == SettingsPane.editor.title)
            #expect(controller.split.model.location == .root(.editor))
            await host.tearDown()
        }

        @Test("A link to a plugin that is not loaded opens Extensions and leaves a reveal for the pane")
        func unloadedPluginLinkBecomesAReveal() async throws {
            let host = try Host()
            let (controller, window) = try host.makeController()

            controller.prepareToShow(SettingsLocation(route: .plugin(id: "com.example.missing")))

            #expect(window.title == SettingsPane.plugins.title)
            #expect(controller.split.model.pendingPluginReveal?.pluginId == "com.example.missing")
            await host.tearDown()
        }

        @Test("Opening the window gives the sidebar list the keyboard, never the search field")
        func sidebarListHoldsFocusOnOpen() async throws {
            let host = try Host()
            let (controller, window) = try host.makeController()

            controller.prepareToShow(nil)

            #expect(window.initialFirstResponder === controller.split.sidebar.tableView)
            #expect(window.firstResponder === controller.split.sidebar.tableView)
            await host.tearDown()
        }

        @Test("A visited pane keeps its host while the window is open, and closing releases it")
        func paneHostsAreRetainedUntilClose() async throws {
            let host = try Host()
            let (controller, _) = try host.makeController()
            let split = controller.split
            controller.prepareToShow(.root(.editor))
            let editor = try #require(split.detail.host(for: .editor))

            split.model.select(.data)
            #expect(editor.view.isHidden)
            split.model.select(.editor)
            #expect(split.detail.host(for: .editor) === editor)
            #expect(split.detail.host(for: .data)?.view.isHidden == true)

            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            #expect(!split.model.canGoBack)
            try await waitUntil { split.detail.host(for: .editor) == nil }
            await host.tearDown()
        }

        @Test("Only Keyboard and Extensions put a filter in the toolbar")
        func paneFilterFollowsThePane() async throws {
            let host = try Host()
            let (controller, window) = try host.makeController()
            controller.prepareToShow(.root(.general))
            let filters = [SettingsWindowToolbar.keyboardSearchIdentifier, SettingsWindowToolbar.extensionsFilterIdentifier]

            #expect(Self.toolbarIdentifiers(of: window).filter { filters.contains($0) }.isEmpty)

            controller.split.model.select(.keyboard)
            #expect(Self.toolbarIdentifiers(of: window).filter { filters.contains($0) } == [SettingsWindowToolbar.keyboardSearchIdentifier])

            controller.split.model.select(.plugins)
            #expect(Self.toolbarIdentifiers(of: window).filter { filters.contains($0) } == [SettingsWindowToolbar.extensionsFilterIdentifier])

            controller.split.model.select(.data)
            #expect(Self.toolbarIdentifiers(of: window).filter { filters.contains($0) }.isEmpty)
            await host.tearDown()
        }

        @Test("The window has a fixed width, can be minimized and never zooms, tabs or restores")
        func windowShape() async throws {
            let host = try Host()
            let (_, window) = try host.makeController()

            #expect(window.identifier?.rawValue == WindowIdentifier.settings)
            #expect(window.contentMinSize == SettingsSplitViewController.minimumContentSize)
            #expect(window.contentMaxSize.width == SettingsSplitViewController.contentWidth)
            #expect(window.styleMask.contains(.miniaturizable))
            #expect(window.standardWindowButton(.zoomButton)?.isEnabled == false)
            #expect(window.tabbingMode == .disallowed)
            #expect(!window.isRestorable)
            #expect(window.titleVisibility == .visible)
            await host.tearDown()
        }

        @Test("present() builds the settings window with its identifier")
        func presentBuildsTheSettingsWindow() async throws {
            let host = try Host()
            host.storePane(.general)
            let controller = SettingsWindowController()
            let window = try #require(controller.window, "Cmd-comma and settings links present this controller")
            window.isReleasedWhenClosed = false
            host.windows.append(window)
            #expect(window.identifier?.rawValue == WindowIdentifier.settings)
            #expect(window.title == SettingsPane.general.title)
            await host.tearDown()
        }
    }
}
