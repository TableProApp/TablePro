//
//  MainWindowToolbar.swift
//  TablePro
//

import AppKit
import Combine
import Observation
import os

@MainActor
internal final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    nonisolated internal static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    /// The autosave name. Bumping it discards every saved arrangement, so it moves only when the
    /// default set changes enough that replaying a stored one would be worse than resetting it. The
    /// v3 move drops the hosted status item and four commands from the default, and a v2 list still
    /// names identifiers the delegate no longer vends. v4 adds the throughput readout: a stored v3
    /// arrangement does not name it, so a reader who had customized the toolbar would never see it.
    internal static let toolbarIdentifier = NSToolbar.Identifier("com.TablePro.main.toolbar.v4")

    /// Which connection the toolbar is about. Every item reads this rather than capturing a
    /// coordinator, so a switch repoints one reference instead of rebuilding the window's whole
    /// titlebar; `NSWindow.toolbar` is never reassigned, which is worth as much as the rebuild
    /// itself, because assigning an already-built toolbar still costs AppKit the titlebar
    /// hierarchy.
    ///
    /// Weak on purpose. The coordinator is owned by `ConnectionWorkspace.sessionState` and leaves
    /// `MainContentCoordinator.activeCoordinators` only on deinit, so a strong reference here
    /// would keep a torn-down connection alive and voting in every aggregate that walks that
    /// registry.
    internal private(set) weak var coordinator: MainContentCoordinator?

    /// The window behind the toolbar, which every connection it points at comes and goes under.
    /// Switch Connection is the window's command, so it cannot be reached through the connection
    /// that just went away.
    internal weak var windowController: MainSplitViewController?

    internal let managedToolbar: NSToolbar
    private var itemStateObservationGeneration = 0
    private var cancellables: Set<AnyCancellable> = []

    /// Which shortcut each item advertises, and the wording it advertises it with. The item cannot
    /// be asked: `NSToolbarItem` has no shortcut of its own, and its `menuFormRepresentation` keeps
    /// only the resolved key, not the action that produced it. Recorded by the factory that already
    /// receives both, so this is not a second list anyone has to keep in step by hand.
    private var shortcutBindings: [NSToolbarItem.Identifier: ToolbarShortcutBinding] = [:]

    /// Which item an overflow-menu entry stands for. AppKit validates an overflowed item as a menu
    /// item rather than as a toolbar item, so `validateToolbarItem(_:)` never runs for it and the
    /// entry stayed enabled while the same button was disabled on a wider window. Recorded by the
    /// factory that already receives both the identifier and the action, for the same reason
    /// `shortcutBindings` is: a second hand-written table drifts.
    private var menuFormIdentifiers: [Selector: NSToolbarItem.Identifier] = [:]

    private(set) var sidebarGroup: NSToolbarItemGroup?

    /// The throughput readout. One item per toolbar rather than one per vend: the ticker writes
    /// into it directly, so it has to be the instance the toolbar is actually showing.
    internal let transportRateItem = TransportRateToolbarItem()

    /// A group holding nothing but the readout, and the reason it exists is that emptying it is how
    /// the readout leaves the toolbar. Measured: an item whose view is hidden keeps its 75pt, and a
    /// view constrained to zero width still leaves a 24pt gap, so neither hides it cleanly.
    /// `NSToolbarItem.isHidden` does, but it is macOS 15 and the app targets 14. An empty group
    /// reclaims the space exactly, on every version, with no availability gate.
    internal private(set) lazy var transportRateGroup: NSToolbarItemGroup = {
        let group = NSToolbarItemGroup(itemIdentifier: TransportRateToolbarItem.identifier)
        let label = String(localized: "Throughput")
        group.label = label
        group.paletteLabel = label
        group.subitems = []
        return group
    }()
    /// Back and forward, held rather than vended fresh, because emptying and refilling this group is
    /// how the pair leaves and rejoins the toolbar. Measured: emptying it drops its platter and
    /// moves nothing else at all (the centred group held x=647.0 midX=772.8 across hidden, shown and
    /// hidden again), and a toggle plus layout cost 9.5ms at worst over twenty flips.
    ///
    /// Apple does not do this. Measured on a running Xcode, its Back/Forward group keeps its full
    /// 75pt capsule with both segments reported DISABLED when there is nowhere to go. This app hides
    /// it instead, by explicit request.
    internal private(set) lazy var navigationGroup: NSToolbarItemGroup = {
        /// Empty to begin with, which is the honest default: a toolbar with no connection behind it
        /// has no history to walk. `syncNavigationVisibility` fills it once there is one.
        let group = makeNativeGroup(
            id: Self.backForwardGroup,
            label: String(localized: "Navigation"),
            subitems: []
        )
        /// `isNavigational` is what puts back and forward on the leading edge of the content title
        /// area, where Finder and Safari keep them.
        group.isNavigational = true
        return group
    }()

    private lazy var navigationSubitems: [NSToolbarItem] = [subitemNavigateBack(), subitemNavigateForward()]

    private var transportSampler = TransportRateSampler()
    private var transportTicker: Task<Void, Never>?

    private static let transportSampleInterval = Duration.seconds(1)

    /// `NSMenu.delegate` is weak, and the safe-mode control's menu is built here rather than by the
    /// menu bar, so this toolbar is what keeps its delegate alive.
    internal let safeModeMenuDelegate = SafeModeMenuDelegate()

    override internal convenience init() {
        self.init(managedToolbar: NSToolbar(identifier: Self.toolbarIdentifier))
    }

    internal init(managedToolbar: NSToolbar) {
        self.managedToolbar = managedToolbar
        super.init()
        self.managedToolbar.delegate = self
        /// The default for a toolbar nobody has customized, which is what Finder ships and what
        /// keeps the titlebar one row tall. It does not overrule the user: measured, an autosaved
        /// display mode is restored when the toolbar reaches its window, which is after this, so a
        /// reader who turns labels on keeps them.
        self.managedToolbar.displayMode = .iconOnly
        self.managedToolbar.allowsUserCustomization = true
        self.managedToolbar.autosavesConfiguration = true
        self.managedToolbar.centeredItemIdentifiers = [Self.connectionGroup]
        /// The hop off `AppSettingsManager.keyboard`'s own `didSet` matters: without it the toolbar
        /// items are mutated re-entrantly, part way through the settings write that triggered them.
        AppEvents.shared.keyboardSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshShortcutHints() }
            .store(in: &cancellables)
    }

    /// A toolbar item's tooltip and its overflow-menu key equivalent are written once, when the
    /// delegate vends the item, and AppKit never revisits either. A rebind in Settings therefore
    /// reaches the menu bar and stops there, leaving the toolbar advertising a key that no longer
    /// runs the command.
    private func refreshShortcutHints() {
        for item in allItems() {
            applyShortcutBinding(to: item)
        }
    }

    /// Records what an item advertises and pushes it onto the item for the first time.
    internal func bindShortcut(_ shortcut: ShortcutAction?, description: String, to item: NSToolbarItem) {
        guard let shortcut else {
            item.toolTip = description
            return
        }
        shortcutBindings[item.itemIdentifier] = ToolbarShortcutBinding(
            shortcut: shortcut,
            description: description
        )
        applyShortcutBinding(to: item)
    }

    /// Records which item an overflow-menu action belongs to, so validation can reach it.
    internal func bindMenuForm(action: Selector, to itemIdentifier: NSToolbarItem.Identifier) {
        menuFormIdentifiers[action] = itemIdentifier
    }

    /// Nil for a menu item this toolbar did not build, which is nobody else's item to validate.
    internal func itemIdentifier(forMenuFormAction action: Selector?) -> NSToolbarItem.Identifier? {
        action.flatMap { menuFormIdentifiers[$0] }
    }

    /// Re-words an item whose description follows the connection, keeping its shortcut hint. Setting
    /// `toolTip` directly at those call sites is what dropped the hint on every connection switch.
    internal func updateShortcutDescription(_ description: String, for id: NSToolbarItem.Identifier) {
        shortcutBindings[id]?.description = description
    }

    internal func applyShortcutBinding(to item: NSToolbarItem) {
        guard let binding = shortcutBindings[item.itemIdentifier] else { return }
        let keyboard = AppSettingsManager.shared.keyboard
        item.toolTip = keyboard.shortcutHint(binding.description, for: binding.shortcut)
        /// An item that opens a submenu has no key equivalent to carry; its menu form is the menu.
        guard let menuItem = item.menuFormRepresentation, menuItem.submenu == nil else { return }
        MenuItemFactory.apply(shortcut: binding.shortcut, keyboard: keyboard, to: menuItem)
    }

    /// `windowDidBecomeKey` runs on activation with the connection unchanged, so without the guard
    /// the window would pay for a switch every time it came forward.
    internal func repoint(to coordinator: MainContentCoordinator?) {
        guard self.coordinator !== coordinator else { return }
        /// The presenter owns the switcher surface, so the dismissal has to be explicit or a
        /// workspace switch would leave the chooser open over the connection it no longer belongs
        /// to. It goes through the window, because a repoint to no connection at all is one of the
        /// switches.
        windowController?.switcherPresenter.dismiss()
        itemStateObservationGeneration += 1
        self.coordinator = coordinator
        observeItemState()
        restartTransportTicker()
        refreshConnectionScopedItems()
        syncSidebarSelection()
        managedToolbar.validateVisibleItems()
    }

    /// Runs only for a connection whose transport the app carries the bytes for, so an ordinary
    /// direct connection costs nothing at all. It writes into the readout's own field rather than
    /// asking the toolbar to revalidate: the field is a fixed width, so a new figure is a redraw
    /// inside one view and never a layout pass.
    private func restartTransportTicker() {
        transportTicker?.cancel()
        transportSampler = TransportRateSampler()
        transportRateItem.apply(rate: nil)
        guard carriesMeasuredTransport else {
            transportTicker = nil
            return
        }

        transportTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.transportSampleInterval)
                guard !Task.isCancelled, let self else { return }
                self.sampleTransportRate()
            }
        }
    }

    private func sampleTransportRate() {
        guard let connection = coordinator?.connection else { return }
        let totals = TransportActivityRegistry.shared.totals(for: connection.id)
        transportRateItem.apply(rate: totals.flatMap { transportSampler.sample($0, at: .now) })
    }

    /// Emptying and refilling the readout's own group is the one structural change AppKit
    /// re-measures. It happens when a connection is adopted, never under a running tunnel, so
    /// nothing moves while a figure is ticking.
    private func syncTransportRateVisibility() {
        let carries = !transportRateGroup.subitems.isEmpty
        guard carries != carriesMeasuredTransport else { return }
        transportRateGroup.subitems = carriesMeasuredTransport ? [transportRateItem] : []
    }

    /// Both arrows go together. Hiding one of a segmented pair would leave a lone half-capsule and
    /// change the group's width on every step through the history, which is a worse read than a
    /// dimmed arrow.
    private func syncNavigationVisibility() {
        let canNavigate = coordinator.map { $0.canNavigateBack || $0.canNavigateForward } ?? false
        let shown = !navigationGroup.subitems.isEmpty
        guard shown != canNavigate else { return }
        navigationGroup.subitems = canNavigate ? navigationSubitems : []
    }

    func invalidate() {
        /// Window close reaches here rather than through `repoint`, and the panel surface is an
        /// independent floating `NSPanel` with no parent-child relationship to the window, so
        /// nothing else would take it down with the window that opened it. A window whose
        /// connection was released has no coordinator to reach it through.
        windowController?.switcherPresenter.dismiss()
        itemStateObservationGeneration += 1
        transportTicker?.cancel()
        transportTicker = nil
        transportRateItem.apply(rate: nil)
        sidebarGroup = nil
        coordinator = nil
    }

    /// What a validation pass depends on beyond the responder chain. `validateVisibleItems()` is
    /// also what re-runs `StatefulToolbarItem.validate()`, so the safe-mode glyph tracks the level
    /// through the same channel rather than through an observer of its own.
    private func observeItemState() {
        let generation = itemStateObservationGeneration
        let coordinatorIdentifier = coordinator.map { ObjectIdentifier($0) }
        withObservationTracking { [weak self] in
            _ = self?.coordinator?.toolbarState.hasPendingChanges
            _ = self?.coordinator?.toolbarState.hasDataPendingChanges
            _ = self?.coordinator?.toolbarState.safeModeLevel
            _ = self?.coordinator?.toolbarState.currentDatabase
            _ = self?.coordinator?.canNavigateBack
            _ = self?.coordinator?.canNavigateForward
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.itemStateObservationGeneration,
                      coordinatorIdentifier == self.coordinator.map({ ObjectIdentifier($0) })
                else { return }
                self.observeItemState()
                self.syncNavigationVisibility()
                self.managedToolbar.validateVisibleItems()
            }
        }
    }

    /// Items carrying text or a menu derived from the connection. Validation cannot repoint them:
    /// a menu built at construction keeps whatever it was built with, and a label is not part of
    /// what `validate()` reconsiders. They are pushed here instead.
    private func refreshConnectionScopedItems() {
        syncTransportRateVisibility()
        syncNavigationVisibility()
        for item in allItems() {
            switch item.itemIdentifier {
            case Self.connection:
                /// The overflow entry carries the glyph too, and it is written once when the item
                /// is vended, so without this a clipped item kept the previous engine's icon.
                item.image = engineGlyph
                item.menuFormRepresentation?.image = engineGlyph
            case Self.database:
                apply(label: containerEntityName, to: item)
                updateShortcutDescription(
                    String(format: String(localized: "Open %@"), containerEntityName),
                    for: Self.database
                )
                applyShortcutBinding(to: item)
            case Self.previewSQL:
                updateShortcutDescription(previewDescription, for: Self.previewSQL)
                applyShortcutBinding(to: item)
            case Self.importTables:
                (item as? NSMenuToolbarItem)?.menu = buildImportSubmenu()
                item.menuFormRepresentation?.submenu = buildImportSubmenu()
            default:
                continue
            }
        }
    }

    /// The overflow menu keeps the title it was built with, so a label change has to reach it too.
    private func apply(label: String, to item: NSToolbarItem) {
        item.label = label
        item.paletteLabel = label
        item.menuFormRepresentation?.title = label
    }

    private func allItems() -> [NSToolbarItem] {
        managedToolbar.items.flatMap { item -> [NSToolbarItem] in
            guard let group = item as? NSToolbarItemGroup else { return [item] }
            return [item] + group.subitems
        }
    }

    // MARK: - Identifiers

    static let connectionGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.connectionGroup")
    static let connection = NSToolbarItem.Identifier("com.TablePro.toolbar.connection")
    static let database = NSToolbarItem.Identifier("com.TablePro.toolbar.database")
    static let refresh = NSToolbarItem.Identifier("com.TablePro.toolbar.refresh")
    static let saveChanges = NSToolbarItem.Identifier("com.TablePro.toolbar.saveChanges")
    static let addRow = NSToolbarItem.Identifier("com.TablePro.toolbar.addRow")
    static let safeMode = NSToolbarItem.Identifier("com.TablePro.toolbar.safeMode")
    static let quickSwitcher = NSToolbarItem.Identifier("com.TablePro.toolbar.quickSwitcher")
    static let newTab = NSToolbarItem.Identifier("com.TablePro.toolbar.newTab")
    static let previewSQL = NSToolbarItem.Identifier("com.TablePro.toolbar.previewSQL")
    static let results = NSToolbarItem.Identifier("com.TablePro.toolbar.results")
    static let inspector = NSToolbarItem.Identifier.toggleInspector
    static let assistant = NSToolbarItem.Identifier("com.TablePro.toolbar.assistant")
    static let dashboard = NSToolbarItem.Identifier("com.TablePro.toolbar.dashboard")
    static let history = NSToolbarItem.Identifier("com.TablePro.toolbar.history")
    static let exportTables = NSToolbarItem.Identifier("com.TablePro.toolbar.export")
    static let importTables = NSToolbarItem.Identifier("com.TablePro.toolbar.import")
    static let refreshSaveGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.refreshSaveGroup")
    static let editorGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.editorGroup")
    static let restorePreviousValues = NSToolbarItem.Identifier("com.TablePro.toolbar.restorePreviousValues")
    static let exportImportGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.exportImportGroup")
    static let sidebarToggle = NSToolbarItem.Identifier("com.TablePro.toolbar.sidebarToggle")
    static let backForwardGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.backForwardGroup")
    static let navigateBack = NSToolbarItem.Identifier("com.TablePro.toolbar.navigateBack")
    static let navigateForward = NSToolbarItem.Identifier("com.TablePro.toolbar.navigateForward")

    // MARK: - NSToolbarDelegate

    /// Items ahead of `.sidebarTrackingSeparator` lay out in the sidebar's own titlebar strip,
    /// so the control that switches what the sidebar shows sits over the pane it drives.
    ///
    /// A tracking separator divides the toolbar into pane-aligned sections; it does not align the
    /// items inside one. Everything after `.inspectorTrackingSeparator` therefore lays out from
    /// that section's leading edge, which is the inspector divider, so the toggle walked inward as
    /// the pane opened and only looked right while the inspector was closed. The `.flexibleSpace`
    /// is what anchors it to the window's trailing edge, and it is the order Apple ships in
    /// WWDC23 session 10054. Keep the toggle last: ahead of the separator it lands in the content
    /// section and is wrong in both states.
    ///
    /// Four runs, and every item in one belongs to the same job, because adjacent items share one
    /// background under Liquid Glass and a run of unrelated singletons reads as scatter. A
    /// `NSToolbarItemGroup` is one control however many subitems it holds, so Table Actions and
    /// the two editor commands are groups rather than five loose buttons.
    ///
    /// The centre is what the window is pointed at: the connection and the container, each a
    /// titled control that opens its own chooser, which is the shape Xcode gives its scheme and
    /// destination. It carries a title rather than a label, so it still reads as words with the
    /// toolbar in icon-only mode. The centred item this replaces was an `NSHostingController`, and
    /// that is the whole reason it used to disappear: measured, a native centred group is still
    /// fully visible at 700pt where the hosted one was dropped at 1000pt, because AppKit can
    /// compress a group it draws itself and can only drop a view it does not.
    ///
    /// Nothing here repeats the window title, which names the tab rather than the connection.
    internal static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarToggle,
        .sidebarTrackingSeparator,
        backForwardGroup,
        .flexibleSpace,
        connectionGroup,
        TransportRateToolbarItem.identifier,
        .flexibleSpace,
        refreshSaveGroup,
        editorGroup,
        safeMode,
        .inspectorTrackingSeparator,
        .flexibleSpace,
        assistant,
        inspector,
    ]

    /// `addRow`, `restorePreviousValues`, `quickSwitcher` and `newTab` are absent on purpose: they
    /// ride a group as subitems and the delegate vends no standalone item for any of them, so
    /// listing one here would offer the customization palette a tile it cannot build.
    internal static let allowedItemIdentifiers: [NSToolbarItem.Identifier] = defaultItemIdentifiers + [
        previewSQL,
        results,
        exportImportGroup,
        dashboard,
        history,
    ]

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }
}

// MARK: - Sidebar Toggle

extension MainWindowToolbar {
    private static let sidebarSegmentTabs: [SidebarTab] = [.tables, .favorites]

    /// A one-of-N segmented toolbar control is `NSToolbarItemGroup` with `.selectOne`.
    /// Hand-building two `NSButton`s meant faking selection with border tricks and a
    /// deprecated bezel, and polling `@Observable` state to keep them in sync.
    ///
    /// The group must not be navigational. `isNavigational` lets AppKit lift an item out of its
    /// declared slot and pin it to the leading edge of the content title area, the way Finder
    /// places back and forward, which put this control past the sidebar divider no matter where
    /// `defaultItemIdentifiers` listed it. Without the flag it lays out in the sidebar's own
    /// titlebar strip, and follows the divider when the sidebar collapses.
    internal static func makeSidebarSegmentGroup(target: AnyObject?, action: Selector) -> NSToolbarItemGroup {
        let images = ["list.bullet", "star"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: sidebarToggle,
            images: images,
            selectionMode: .selectOne,
            labels: [String(localized: "Tables"), String(localized: "Favorites")],
            target: target,
            action: action
        )
        group.label = String(localized: "Sidebar")
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        return group
    }

    /// `sidebarGroup` is the one handle `syncSidebarSelection()` has on the live control, so only
    /// the item actually going into the toolbar may claim it. A Customize Toolbar palette copy
    /// that took the slot left every later sync writing into a discarded group, and the segments
    /// stopped following the sidebar until the window was reopened.
    internal func makeSidebarToggleItem(claimsSlot: Bool) -> NSToolbarItem {
        let group = Self.makeSidebarSegmentGroup(target: self, action: #selector(sidebarSegmentChanged(_:)))
        bindMenuForm(action: #selector(sidebarSegmentChanged(_:)), to: Self.sidebarToggle)
        guard claimsSlot else { return group }
        sidebarGroup = group
        syncSidebarSelection()
        return group
    }

    /// `@objc` does not type-check the sender, and this action is reachable from the overflow menu
    /// as well as from the control, where AppKit sends an `NSMenuItem`. A typed parameter would
    /// read `selectedIndex` off it and trap on `doesNotRecognizeSelector`.
    @objc fileprivate func sidebarSegmentChanged(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        let index = group.selectedIndex
        guard Self.sidebarSegmentTabs.indices.contains(index) else { return }
        coordinator?.splitViewController?.setSidebarTab(Self.sidebarSegmentTabs[index])
    }

    /// Pushed from the split view controller whenever the sidebar tab or its collapsed
    /// state changes, instead of an observation loop watching for it.
    internal func syncSidebarSelection() {
        guard let group = sidebarGroup else { return }
        let tab = coordinator?.splitViewController?.selectedSidebarTab
        group.selectedIndex = tab.flatMap(Self.sidebarSegmentTabs.firstIndex(of:)) ?? -1
        managedToolbar.validateVisibleItems()
    }
}
