//
//  SettingsWindowController.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI

// An AppKit window, so the app needs no SwiftUI Settings scene (which would rewrite NSApp.mainMenu).
@MainActor
internal final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    internal static func present(pane: SettingsPane? = nil) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.split?.navigate(to: pane)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private var split: SettingsSplitViewController? {
        contentViewController as? SettingsSplitViewController
    }

    // A defaulted parameter would let `SettingsWindowController()` resolve to the inherited `init()`, which builds no window.
    internal convenience init() {
        self.init(registryClient: .shared)
    }

    internal convenience init(registryClient: RegistryClient) {
        let split = SettingsSplitViewController(registryClient: registryClient)

        // NSWindow(contentViewController:) binds the title to the split controller's, which mirrors the selected row.
        let window = NSWindow(contentViewController: split)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.settings)
        window.keepsKeyViewLoopCurrent()
        window.styleMask = [.titled, .closable, .resizable]
        // The detail's NavigationStack renders its back button and title into the window toolbar;
        // a transparent titlebar lets the sidebar material flow full-height under it (no empty band).
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        // Width fixed (sidebar + detail); height resizes.
        window.contentMinSize = SettingsSplitViewController.minimumContentSize
        window.contentMaxSize = NSSize(width: SettingsSplitViewController.minimumContentSize.width, height: .greatestFiniteMagnitude)
        window.setContentSize(SettingsSplitViewController.defaultContentSize)
        window.applyAutosaveName(WindowIdentifier.settings)
        window.setContentSize(
            NSSize(
                width: SettingsSplitViewController.minimumContentSize.width,
                height: max(window.contentLayoutRect.height, SettingsSplitViewController.minimumContentSize.height)
            )
        )
        self.init(window: window)
    }
}

// The sidebar list + detail pane. Replaces the twelve-item .preference toolbar; a scrolling
// sidebar has no item cap, and the detail hosts a NavigationStack so a row can push sub-pages.
internal final class SettingsSplitViewController: NSSplitViewController {
    // System Settings keeps a fixed width and resizes in height only.
    internal static let minimumContentSize = NSSize(width: sidebarWidth + detailMinWidth, height: 480)
    internal static let defaultContentSize = NSSize(width: sidebarWidth + detailMinWidth, height: 700)
    private static let sidebarWidth: CGFloat = 248
    private static let detailMinWidth: CGFloat = 520

    private static let logger = Logger(subsystem: "com.TablePro", category: "SettingsWindow")

    internal let model: SettingsNavigationModel
    private let registryClient: RegistryClient
    private var cancellables: Set<AnyCancellable> = []

    internal init(registryClient: RegistryClient = .shared) {
        self.registryClient = registryClient
        self.model = SettingsNavigationModel(initial: Self.persistedPane)
        super.init(nibName: nil, bundle: nil)
        title = model.selection.title
    }

    internal required init?(coder: NSCoder) {
        fatalError("SettingsSplitViewController does not support NSCoder init")
    }

    private static var persistedPane: SettingsPane {
        let stored = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
        guard let stored, let pane = SettingsPane(rawValue: stored) else { return SettingsNavigation.defaultPane }
        return pane
    }

    // A user click persists as the new last-used pane; a programmatic jump (openSettings, deep link)
    // navigates without clobbering it.
    internal func navigate(to pane: SettingsPane?) {
        _ = view // loads the view on every supported macOS, which attaches the selection observer
        model.applyProgrammatic(pane ?? Self.persistedPane)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebar = NSHostingController(rootView: SettingsSidebarView(model: model))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detail = NSHostingController(rootView: SettingsDetailView(model: model, registryClient: registryClient))
        // A split item's hosting controller fixes its fitting size as a required minimum unless this is cleared.
        detail.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = Self.detailMinWidth
        detailItem.holdingPriority = NSLayoutConstraint.Priority(260) // below dragThatCannotResizeWindow (490)
        addSplitViewItem(detailItem)

        model.$selection
            .removeDuplicates()
            .sink { [weak self] pane in
                self?.title = pane.title
                self?.persistUserSelection(pane)
            }
            .store(in: &cancellables)
    }

    private func persistUserSelection(_ pane: SettingsPane) {
        guard !model.isApplyingProgrammatic else { return }
        AppStorageEnvironment.shared.defaults.set(pane.rawValue, forKey: PreferenceKeys.selectedSettingsPane.name)
    }
}

@MainActor
internal final class SettingsNavigationModel: ObservableObject {
    @Published internal var selection: SettingsPane
    @Published internal var searchText: String = ""
    internal private(set) var isApplyingProgrammatic = false

    internal init(initial: SettingsPane) {
        self.selection = initial
    }

    // From the sidebar list: the user picked a row, so it becomes the last-used pane.
    internal func userSelect(_ pane: SettingsPane) {
        isApplyingProgrammatic = false
        selection = pane
    }

    // From openSettings / a deep link: show the pane but do not rewrite the last-used pane.
    internal func applyProgrammatic(_ pane: SettingsPane) {
        isApplyingProgrammatic = true
        selection = pane
        isApplyingProgrammatic = false
    }
}

private struct SettingsSidebarView: View {
    @ObservedObject fileprivate var model: SettingsNavigationModel

    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { model.selection },
            set: { if let pane = $0 { model.userSelect(pane) } }
        )
    }

    fileprivate var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $model.searchText, placeholder: String(localized: "Search"))
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            List(selection: selectionBinding) {
                ForEach(SettingsNavigation.sections, id: \.id) { section in
                    let panes = visiblePanes(in: section)
                    if !panes.isEmpty {
                        Section {
                            ForEach(panes, id: \.self) { pane in
                                Label {
                                    Text(pane.title)
                                } icon: {
                                    SettingsRowIcon(systemName: pane.symbol, tint: pane.tint)
                                }
                                .tag(Optional(pane))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func visiblePanes(in section: SettingsSection) -> [SettingsPane] {
        let matches = Set(SettingsNavigation.panes(matching: model.searchText))
        return section.panes.filter(matches.contains)
    }
}

private struct SettingsDetailView: View {
    @ObservedObject fileprivate var model: SettingsNavigationModel
    fileprivate let registryClient: RegistryClient

    fileprivate var body: some View {
        // Each pane owns its own stack, keyed by selection, so switching panes resets its depth.
        SettingsPaneStack(pane: model.selection, registryClient: registryClient)
            .id(model.selection)
            .environment(\.appServices, .live)
    }
}

private struct SettingsPaneStack: View {
    fileprivate let pane: SettingsPane
    fileprivate let registryClient: RegistryClient
    @State private var path = NavigationPath()

    fileprivate var body: some View {
        NavigationStack(path: $path) {
            SettingsPaneContent(pane: pane, registryClient: registryClient, path: $path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(pane.title)
        }
    }
}

// A pushed drill-in page. Back button and title come from the NavigationStack.
private struct SettingsSubpageView: View {
    @ObservedObject fileprivate var settingsManager: AppSettingsManager
    fileprivate let subpage: SettingsSubpage

    fileprivate var body: some View {
        content
            .settingsDrillIn(title: subpage.title)
    }

    @ViewBuilder private var content: some View {
        switch subpage {
        case .softwareUpdate:
            Form { SoftwareUpdateSection(updater: SoftwareUpdater.shared, updates: .shared) }
                .formStyle(.grouped)
        case .commandLine:
            Form { CommandLineToolSection() }
                .formStyle(.grouped)
        case .manageThemes:
            // Not wrapped in a Form: a List inside a grouped Form does not scroll on macOS.
            ThemeLibrarySection()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sqlFormatting:
            Form { FormatterSection(settings: $settingsManager.formatter, editor: settingsManager.editor) }
                .formStyle(.grouped)
        case .queryHistory:
            Form { HistorySection(settings: $settingsManager.history) }
                .formStyle(.grouped)
        case .dataRewind:
            Form { DataRewindSection(settings: $settingsManager.history) }
                .formStyle(.grouped)
        case .whatSyncs:
            Form { SyncCategoriesSection(settingsManager: settingsManager) }
                .formStyle(.grouped)
        }
    }
}

private struct SettingsPaneContent: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared

    private let pane: SettingsPane
    private let registryClient: RegistryClient
    private let path: Binding<NavigationPath>

    fileprivate init(pane: SettingsPane, registryClient: RegistryClient, path: Binding<NavigationPath>) {
        self.pane = pane
        self.registryClient = registryClient
        self.path = path
    }

    fileprivate var body: some View {
        paneContent
            .navigationDestination(for: SettingsSubpage.self) { subpage in
                SettingsSubpageView(settingsManager: settingsManager, subpage: subpage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            GeneralSettingsView(
                settings: $settingsManager.general,
                onResetAll: { settingsManager.resetToDefaults() }
            )
        case .sidebar:
            SidebarTabsSettingsView(
                settings: $settingsManager.general,
                tabSettings: $settingsManager.tabs
            )
        case .connections:
            ConnectionsSettingsView(settings: $settingsManager.general)
        case .appearance:
            AppearanceSettingsView(settings: $settingsManager.appearance)
        case .editor:
            EditorSettingsView(
                settings: $settingsManager.editor,
                typography: $settingsManager.typography
            )
        case .data:
            DataResultsSettingsView(
                dataGrid: $settingsManager.dataGrid,
                valueColors: $settingsManager.valueColors,
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
            InstalledPluginsView(registryClient: registryClient, path: path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sync:
            SyncSettingsView()
        case .account:
            AccountSettingsView(model: AccountSettingsModel(services: .shared))
        }
    }
}
