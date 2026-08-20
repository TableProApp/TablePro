//
//  SettingsWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts the settings panes in an AppKit window so the app no longer needs a SwiftUI `Settings`
/// scene. One instance is kept for the app's lifetime, matching the single-window scene it
/// replaces.
@MainActor
internal final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    internal static func present() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.paneController?.selectPersistedPane()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var paneController: SettingsPaneTabViewController? {
        contentViewController as? SettingsPaneTabViewController
    }

    private convenience init() {
        let panes = SettingsPaneTabViewController(nibName: nil, bundle: nil)

        let window = NSWindow(contentViewController: panes)
        window.title = String(localized: "Settings")
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.settings)
        window.styleMask = [.titled, .closable, .resizable]
        window.toolbarStyle = .preference
        window.isRestorable = false
        window.setContentSize(SettingsPaneTabViewController.paneSize)
        window.setFrameAutosaveName(WindowIdentifier.settings)
        /// A programmatic window keeps whatever origin AppKit gave it, so the first launch
        /// after the SwiftUI scene is gone has no saved frame to restore.
        if !window.setFrameUsingName(WindowIdentifier.settings) {
            window.center()
        }
        /// A frame saved before the window became resizable can be smaller than any pane can
        /// draw, so a restored frame is grown back to the pane minimum.
        window.setContentSize(
            NSSize(
                width: max(window.contentLayoutRect.width, SettingsPaneTabViewController.paneSize.width),
                height: max(window.contentLayoutRect.height, SettingsPaneTabViewController.paneSize.height)
            )
        )
        self.init(window: window)
    }
}

private final class SettingsPaneTabViewController: NSTabViewController {
    fileprivate static let paneSize = NSSize(width: 720, height: 500)

    private static let paneOrder: [SettingsPane] = [
        .general, .appearance, .editor, .data, .keyboard, .ai, .mcp, .plugins, .account,
    ]

    private var persistedPane: SettingsPane {
        let stored = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
        guard let stored, let pane = SettingsPane(rawValue: stored) else { return .general }
        return pane
    }

    fileprivate func selectPersistedPane() {
        loadViewIfNeeded()
        select(persistedPane)
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
        view.window?.title = pane.title
    }

    private func select(_ pane: SettingsPane) {
        guard let index = Self.paneOrder.firstIndex(of: pane) else { return }
        selectedTabViewItemIndex = index
        view.window?.title = pane.title
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
        /// A standalone window wants the content's minimum to become the window's, unlike a
        /// split pane's host, where the same minimum would pin the window's dividers.
        hosting.sizingOptions = [.minSize]

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
        case .ai:
            AISettingsView(settings: $settingsManager.ai)
        case .mcp:
            MCPSettingsView(settings: $settingsManager.mcp)
        case .plugins:
            PluginsSettingsView()
        case .account:
            AccountSettingsView()
        }
    }
}
