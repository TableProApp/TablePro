//
//  SettingsWindowController.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

/// Hosts the settings panes in an AppKit window so the app no longer needs a SwiftUI `Settings`
/// scene. One instance is kept for the app's lifetime, matching the single-window scene it
/// replaces.
@MainActor
internal final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    internal static func present(pane: SettingsPane? = nil) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.paneController?.select(pane)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private var paneController: SettingsPaneTabViewController? {
        contentViewController as? SettingsPaneTabViewController
    }

    internal convenience init() {
        let panes = SettingsPaneTabViewController(nibName: nil, bundle: nil)

        /// `NSWindow(contentViewController:)` binds the window title to the content view
        /// controller's own title, so the selected pane publishes the title and nothing writes
        /// `window.title` directly.
        let window = NSWindow(contentViewController: panes)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.settings)
        window.styleMask = [.titled, .closable, .resizable]
        window.toolbarStyle = .preference
        window.isRestorable = false
        window.contentMinSize = SettingsPaneTabViewController.paneSize
        window.setContentSize(SettingsPaneTabViewController.paneSize)
        window.applyAutosaveName(WindowIdentifier.settings)
        /// `contentMinSize` only constrains a user drag, so a frame saved before the window had
        /// a minimum is grown back to the pane minimum on restore.
        window.setContentSize(
            NSSize(
                width: max(window.contentLayoutRect.width, SettingsPaneTabViewController.paneSize.width),
                height: max(window.contentLayoutRect.height, SettingsPaneTabViewController.paneSize.height)
            )
        )
        self.init(window: window)
    }
}

internal final class SettingsPaneTabViewController: NSTabViewController {
    internal static let paneSize = NSSize(width: 720, height: 500)
    internal static let paneOrder: [SettingsPane] = SettingsPane.allCases

    private static let logger = Logger(subsystem: "com.TablePro", category: "SettingsWindow")

    private var persistedPane: SettingsPane {
        let stored = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
        guard let stored, let pane = SettingsPane(rawValue: stored) else { return .general }
        return pane
    }

    internal func select(_ pane: SettingsPane?) {
        loadViewIfNeeded()
        let wanted = pane ?? persistedPane
        guard let index = Self.paneOrder.firstIndex(of: wanted) else {
            Self.logger.error("Settings pane \(wanted.rawValue, privacy: .public) has no tab and cannot be shown")
            return
        }
        selectedTabViewItemIndex = index
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        /// Adding the first item selects it, which persists `.general` over the pane a caller
        /// asked for, so the pane to restore is read while no item exists yet.
        let restored = persistedPane
        for pane in Self.paneOrder {
            addTabViewItem(makeTabViewItem(for: pane))
        }
        select(restored)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let identifier = tabViewItem?.identifier as? String,
              let pane = SettingsPane(rawValue: identifier) else { return }
        AppStorageEnvironment.shared.defaults.set(pane.rawValue, forKey: PreferenceKeys.selectedSettingsPane.name)
    }

    private func makeTabViewItem(for pane: SettingsPane) -> NSTabViewItem {
        let content = SettingsPaneContent(pane: pane)
            .frame(
                minWidth: Self.paneSize.width,
                maxWidth: .infinity,
                minHeight: Self.paneSize.height,
                maxHeight: .infinity
            )
            .environment(UpdaterBridge.shared)
            .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        /// A tab child publishes no size to the window, which owns its minimum through
        /// `contentMinSize`. Its title does travel: `NSTabViewController` mirrors the selected
        /// child's title into its own, and the window's title is bound to that.
        hosting.sizingOptions = []
        hosting.title = pane.title

        let item = NSTabViewItem(viewController: hosting)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.identifier = pane.rawValue
        return item
    }
}

private struct SettingsPaneContent: View {
    @Bindable private var settingsManager = AppSettingsManager.shared

    private let pane: SettingsPane

    fileprivate init(pane: SettingsPane) {
        self.pane = pane
    }

    fileprivate var body: some View {
        switch pane {
        case .general:
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                updaterBridge: UpdaterBridge.shared,
                onResetAll: { settingsManager.resetToDefaults() }
            )
        case .appearance:
            AppearanceSettingsView(settings: $settingsManager.appearance)
        case .editor:
            EditorSettingsView(settings: $settingsManager.editor)
        case .data:
            DataResultsSettingsView(
                dataGrid: $settingsManager.dataGrid,
                history: $settingsManager.history,
                editor: $settingsManager.editor
            )
        case .keyboard:
            KeyboardSettingsView(settings: $settingsManager.keyboard)
        case .notifications:
            NotificationsSettingsView(settings: $settingsManager.notifications)
        case .ai:
            AISettingsView(settings: $settingsManager.ai)
        case .mcp:
            MCPSettingsView(settings: $settingsManager.mcp)
        case .plugins:
            PluginsSettingsView()
        case .sync:
            SyncSettingsView()
        case .account:
            LicenseSettingsView()
        }
    }
}
