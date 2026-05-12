//
//  MainWindowToolbar.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit

@MainActor
internal final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    weak var coordinator: MainContentCoordinator?

    internal let managedToolbar: NSToolbar

    /// Retain hosting controllers per item identifier. NSHostingController is not retained by NSToolbarItem,
    /// so without this its view orphans and the toolbar item collapses to zero width.
    internal var hostingControllers: [NSToolbarItem.Identifier: NSHostingController<AnyView>] = [:]
    var sidebarButtons: [NSButton] = []
    var sidebarObservationTask: Task<Void, Never>?
    var splitViewObserver: NSObjectProtocol?

    internal init(coordinator: MainContentCoordinator) {
        self.coordinator = coordinator
        // Unique identifier per toolbar instance prevents tab-group merging that would collapse
        // all tabs into one toolbar and leave subsequent windows blank.
        self.managedToolbar = NSToolbar(identifier: "com.TablePro.main.toolbar.\(UUID().uuidString)")
        super.init()
        self.managedToolbar.delegate = self
        self.managedToolbar.displayMode = .iconOnly
        self.managedToolbar.allowsUserCustomization = true
        self.managedToolbar.autosavesConfiguration = false
    }

    func invalidate() {
        sidebarObservationTask?.cancel()
        sidebarObservationTask = nil
        if let observer = splitViewObserver {
            NotificationCenter.default.removeObserver(observer)
            splitViewObserver = nil
        }
        sidebarButtons = []
        hostingControllers.removeAll()
        coordinator = nil
    }

    // MARK: - Identifiers

    static let connectionGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.connectionGroup")
    static let connection = NSToolbarItem.Identifier("com.TablePro.toolbar.connection")
    static let database = NSToolbarItem.Identifier("com.TablePro.toolbar.database")
    static let refresh = NSToolbarItem.Identifier("com.TablePro.toolbar.refresh")
    static let saveChanges = NSToolbarItem.Identifier("com.TablePro.toolbar.saveChanges")
    static let principal = NSToolbarItem.Identifier("com.TablePro.toolbar.principal")
    static let quickSwitcher = NSToolbarItem.Identifier("com.TablePro.toolbar.quickSwitcher")
    static let newTab = NSToolbarItem.Identifier("com.TablePro.toolbar.newTab")
    static let previewSQL = NSToolbarItem.Identifier("com.TablePro.toolbar.previewSQL")
    static let results = NSToolbarItem.Identifier("com.TablePro.toolbar.results")
    static let inspector = NSToolbarItem.Identifier.toggleInspector
    static let dashboard = NSToolbarItem.Identifier("com.TablePro.toolbar.dashboard")
    static let history = NSToolbarItem.Identifier("com.TablePro.toolbar.history")
    static let exportTables = NSToolbarItem.Identifier("com.TablePro.toolbar.export")
    static let importTables = NSToolbarItem.Identifier("com.TablePro.toolbar.import")
    static let refreshSaveGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.refreshSaveGroup")
    static let exportImportGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.exportImportGroup")
    static let sidebarToggle = NSToolbarItem.Identifier("com.TablePro.toolbar.sidebarToggle")

    // MARK: - NSToolbarDelegate

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarToggle,
            .sidebarTrackingSeparator,
            Self.connectionGroup,
            Self.refreshSaveGroup,
            .flexibleSpace,
            Self.principal,
            .flexibleSpace,
            Self.quickSwitcher,
            Self.newTab,
            Self.previewSQL,
            Self.inspector,
        ]
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [
            Self.results,
            Self.exportImportGroup,
            Self.dashboard,
            Self.history,
        ]
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        Self.lifecycleLogger.info(
            "[open] toolbar delegate buildItem id=\(itemIdentifier.rawValue, privacy: .public) hasCoordinator=\(self.coordinator != nil)"
        )
        guard let coordinator else { return nil }

        switch itemIdentifier {
        case Self.sidebarToggle:
            return makeSidebarToggleItem(coordinator: coordinator)
        case Self.connectionGroup:
            return makeGroup(
                id: itemIdentifier,
                label: String(localized: "Connection"),
                subitems: [subitemConnection(), subitemDatabase()],
                content: HStack(spacing: 4) {
                    ConnectionToolbarButton(coordinator: coordinator)
                    DatabaseToolbarButton(coordinator: coordinator)
                }
            )
        case Self.principal:
            let item = hostingItem(
                id: itemIdentifier,
                label: "",
                symbol: nil,
                action: nil,
                keyEquivalent: "",
                modifiers: [],
                content: ToolbarPrincipalContent(
                    state: coordinator.toolbarState,
                    onSwitchDatabase: { [weak coordinator] in coordinator?.commandActions?.openDatabaseSwitcher() },
                    onCancelQuery: { [weak coordinator] in coordinator?.cancelCurrentQuery() }
                )
            )
            item.visibilityPriority = .high
            return item
        case Self.quickSwitcher:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Quick Switcher"),
                symbol: "magnifyingglass",
                action: #selector(performOpenQuickSwitcher(_:)),
                keyEquivalent: "o",
                modifiers: [.command, .shift],
                content: QuickSwitcherToolbarButton(coordinator: coordinator)
            )
        case Self.newTab:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "New Tab"),
                symbol: "plus.rectangle",
                action: #selector(performNewTab(_:)),
                keyEquivalent: "t",
                modifiers: .command,
                content: NewTabToolbarButton(coordinator: coordinator)
            )
        case Self.previewSQL:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Preview"),
                symbol: "eye",
                action: #selector(performPreviewSQL(_:)),
                keyEquivalent: "p",
                modifiers: [.command, .shift],
                content: PreviewSQLToolbarButton(coordinator: coordinator)
            )
        case Self.results:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Results"),
                symbol: "rectangle.bottomhalf.inset.filled",
                action: #selector(performToggleResults(_:)),
                keyEquivalent: "r",
                modifiers: [.command, .option],
                content: ResultsToolbarButton(coordinator: coordinator)
            )
        case Self.inspector:
            let item = NSToolbarItem(itemIdentifier: Self.inspector)
            item.label = String(localized: "Inspector")
            item.paletteLabel = String(localized: "Inspector")
            return item
        case Self.dashboard:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "Dashboard"),
                symbol: "gauge.with.dots.needle.33percent",
                action: #selector(performShowDashboard(_:)),
                keyEquivalent: "",
                modifiers: [],
                content: DashboardToolbarButton(coordinator: coordinator)
            )
        case Self.history:
            return hostingItem(
                id: itemIdentifier,
                label: String(localized: "History"),
                symbol: "clock",
                action: #selector(performToggleHistory(_:)),
                keyEquivalent: "y",
                modifiers: .command,
                content: HistoryToolbarButton(coordinator: coordinator)
            )
        case Self.refreshSaveGroup:
            return makeGroup(
                id: itemIdentifier,
                label: String(localized: "Refresh & Save"),
                subitems: [subitemRefresh(), subitemSaveChanges()],
                content: HStack(spacing: 4) {
                    RefreshToolbarButton(coordinator: coordinator)
                    SaveChangesToolbarButton(coordinator: coordinator)
                }
            )
        case Self.exportImportGroup:
            return makeGroup(
                id: itemIdentifier,
                label: String(localized: "Export & Import"),
                subitems: [subitemExport(), subitemImport()],
                content: HStack(spacing: 4) {
                    ExportToolbarButton(coordinator: coordinator)
                    ImportToolbarButton(coordinator: coordinator)
                }
            )
        default:
            return nil
        }
    }
}

// MARK: - Sidebar Toggle

extension MainWindowToolbar {
    fileprivate func makeSidebarToggleItem(coordinator: MainContentCoordinator) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.sidebarToggle)
        item.label = String(localized: "Sidebar")
        item.paletteLabel = String(localized: "Sidebar")

        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 2

        let tablesButton = makeSidebarNSButton(
            icon: "list.bullet",
            label: String(localized: "Tables"),
            tag: 0
        )
        let favoritesButton = makeSidebarNSButton(
            icon: "star",
            label: String(localized: "Favorites"),
            tag: 1
        )

        container.addArrangedSubview(tablesButton)
        container.addArrangedSubview(favoritesButton)

        sidebarButtons = [tablesButton, favoritesButton]
        item.view = container

        syncSidebarButtonState(coordinator: coordinator)
        startSidebarObservation(coordinator: coordinator)

        return item
    }

    private func makeSidebarNSButton(icon: String, label: String, tag: Int) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.setButtonType(.momentaryPushIn)
        button.showsBorderOnlyWhileMouseInside = true
        button.isBordered = true
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.tag = tag
        button.target = self
        button.action = #selector(sidebarButtonClicked(_:))
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    @objc fileprivate func sidebarButtonClicked(_ sender: NSButton) {
        guard let coordinator else { return }
        let tabs: [SidebarTab] = [.tables, .favorites]
        guard sender.tag >= 0, sender.tag < tabs.count else { return }
        coordinator.splitViewController?.setSidebarTab(tabs[sender.tag])
    }

    fileprivate func syncSidebarButtonState(coordinator: MainContentCoordinator) {
        guard sidebarButtons.count == 2 else { return }
        let state = coordinator.toolbarState
        let sidebarState = SharedSidebarState.forConnection(coordinator.connectionId)
        let isConnected = state.connectionState == .connected || state.connectionState == .executing
        let sidebarVisible = !(coordinator.splitViewController?.isSidebarCollapsed ?? true)
        let icons = ["list.bullet", "star"]
        let activeIcons = ["list.bullet", "star.fill"]

        for (index, button) in sidebarButtons.enumerated() {
            let isActive = sidebarVisible && isConnected
                && (index == 0 ? sidebarState.selectedSidebarTab == .tables : sidebarState.selectedSidebarTab == .favorites)
            button.isEnabled = isConnected
            button.showsBorderOnlyWhileMouseInside = !isActive
            let icon = isActive ? activeIcons[index] : icons[index]
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: button.accessibilityLabel())
        }
    }

    fileprivate func startSidebarObservation(coordinator: MainContentCoordinator) {
        sidebarObservationTask?.cancel()

        sidebarObservationTask = Task { [weak self, weak coordinator] in
            guard let coordinator else { return }
            while !Task.isCancelled {
                let sidebarState = SharedSidebarState.forConnection(coordinator.connectionId)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = coordinator.toolbarState.connectionState
                        _ = sidebarState.selectedSidebarTab
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.syncSidebarButtonState(coordinator: coordinator)
                }
            }
        }

        splitViewObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: coordinator.splitViewController?.splitView,
            queue: .main
        ) { [weak self, weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let self, let coordinator else { return }
                self.syncSidebarButtonState(coordinator: coordinator)
            }
        }
    }
}
