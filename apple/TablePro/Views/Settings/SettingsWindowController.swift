//
//  SettingsWindowController.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

// An AppKit window, so the app needs no SwiftUI Settings scene.
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

    // A defaulted parameter would let `SettingsWindowController()` resolve to the inherited `init()`, which builds no window.
    internal convenience init() {
        self.init(registryClient: .shared)
    }

    internal convenience init(registryClient: RegistryClient) {
        let panes = SettingsPaneTabViewController(registryClient: registryClient)

        // NSWindow(contentViewController:) binds the title to the panes controller's, so nothing writes window.title.
        let window = NSWindow(contentViewController: panes)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.settings)
        window.keepsKeyViewLoopCurrent()
        window.styleMask = [.titled, .closable, .resizable]
        window.toolbarStyle = .preference
        window.isRestorable = false
        window.contentMinSize = SettingsPaneTabViewController.paneSize
        window.setContentSize(SettingsPaneTabViewController.paneSize)
        window.applyAutosaveName(WindowIdentifier.settings)
        // contentMinSize only limits a drag, so a frame saved before the window had a minimum is grown back here.
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
    // Fits twelve items in a .preference toolbar; at 720 the last one hides behind an overflow chevron.
    internal static let paneSize = NSSize(width: 800, height: 500)
    internal static let paneOrder: [SettingsPane] = SettingsPane.allCases

    private static let logger = Logger(subsystem: "com.TablePro", category: "SettingsWindow")

    private let registryClient: RegistryClient

    internal init(registryClient: RegistryClient = .shared) {
        self.registryClient = registryClient
        super.init(nibName: nil, bundle: nil)
    }

    internal required init?(coder: NSCoder) {
        fatalError("SettingsPaneTabViewController does not support NSCoder init")
    }

    private var persistedPane: SettingsPane {
        let stored = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
        guard let stored, let pane = SettingsPane(rawValue: stored) else { return .general }
        return pane
    }

    internal func select(_ pane: SettingsPane?) {
        // Before macOS 14, reading view loads it, which is all loadViewIfNeeded() does.
        if #available(macOS 14.0, *) {
            loadViewIfNeeded()
        } else {
            _ = view
        }
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
        // Adding the first item selects and persists .general, so the saved pane is read before any item exists.
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
        let content = SettingsPaneContent(pane: pane, registryClient: registryClient)
            .frame(
                minWidth: Self.paneSize.width,
                maxWidth: .infinity,
                minHeight: Self.paneSize.height,
                maxHeight: .infinity
            )
            .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        // The window owns the minimum size; the title still reaches it, as NSTabViewController mirrors the selected child's.
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
    @ObservedObject private var settingsManager = AppSettingsManager.shared

    private let pane: SettingsPane
    private let registryClient: RegistryClient

    fileprivate init(pane: SettingsPane, registryClient: RegistryClient) {
        self.pane = pane
        self.registryClient = registryClient
    }

    fileprivate var body: some View {
        switch pane {
        case .general:
            GeneralSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs,
                dataGridSettings: $settingsManager.dataGrid,
                editorSettings: $settingsManager.editor,
                appearanceSettings: $settingsManager.appearance,
                updater: SoftwareUpdater.shared,
                onResetAll: { settingsManager.resetToDefaults() }
            )
        case .appearance:
            AppearanceSettingsView(settings: $settingsManager.appearance)
        case .editor:
            EditorSettingsView(
                settings: $settingsManager.editor,
                formatter: $settingsManager.formatter,
                typography: $settingsManager.typography
            )
        case .data:
            DataResultsSettingsView(
                dataGrid: $settingsManager.dataGrid,
                valueColors: $settingsManager.valueColors,
                history: $settingsManager.history,
                editor: $settingsManager.editor,
                typography: $settingsManager.typography
            )
        case .keyboard:
            KeyboardSettingsView(settings: $settingsManager.keyboard)
        case .profiles:
            ProfilesSettingsView()
        case .notifications:
            NotificationsSettingsView(settings: $settingsManager.notifications)
        case .ai:
            AISettingsView(settings: $settingsManager.ai)
        case .mcp:
            MCPSettingsView(settings: $settingsManager.mcp)
        case .plugins:
            InstalledPluginsView(registryClient: registryClient)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sync:
            SyncSettingsView()
        case .account:
            AccountSettingsView(model: AccountSettingsModel(services: .shared))
        }
    }
}
