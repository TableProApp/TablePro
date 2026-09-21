//
//  MainWindowToolbar.swift
//  TablePro
//

import AppKit
import Combine
import os

@MainActor
internal final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    private var itemStateObservation: AnyCancellable?
    private var tabStateObservation: AnyCancellable?
    nonisolated internal static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    /// The autosave name, and deliberately not bumped when the default set changes.
    ///
    /// Measured on macOS 27 across separate process launches under one identifier: AppKit diffs the
    /// stored `TB Default Item Identifiers` against the current default list and splices a new
    /// identifier in at its position in that list rather than at the end, so a stored
    /// `[alpha, charlie]` against a new default `[alpha, bravo, charlie, delta]` came back
    /// `[alpha, bravo, charlie]`, and an identifier the delegate stops vending is pruned from the
    /// record on the next launch. A user who customized keeps their arrangement and still receives
    /// new items where they belong; a bump would throw that away along with their display mode.
    /// The record is six keys and `isHidden` is not among them, since it is runtime state that is
    /// never persisted, so a context-sensitive item set is no reason to bump either.
    ///
    /// Bump only for a change that diff cannot express, and say which. Neither fact was measured on
    /// macOS 13 or 14.
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

    /// What the app last took out of the titlebar, written by `apply(_:)` and by nothing else.
    ///
    /// The switcher reads this to decide whether its anchor is reachable, because the palette
    /// poisons AppKit's own answer for good: see `ToolbarVisibility`.
    internal private(set) var visibility = ToolbarVisibility()

    /// The slow-moving half of the context the visibility and the commit verb were last applied
    /// from. A keystroke builds a fresh key and compares it with this, and writes nothing unless it
    /// moved, which is what keeps the titlebar from moving while the user types.
    private var appliedVisibilityKey: ToolbarContext.VisibilityKey?

    /// The context of the validation pass in progress, and nil between passes. See
    /// `validationContext()`.
    private var validationPassContext: ToolbarContext?

    /// Coalesces the passes Customize Toolbar asks for, so a drop of several items is one pass.
    private var isVisibilityReapplyScheduled = false

    /// `NSMenu.delegate` is weak, and the safe-mode control's menu is built here rather than by the
    /// menu bar, so this toolbar is what keeps its delegate alive.
    internal let safeModeMenuDelegate = SafeModeMenuDelegate()

    /// The import formats, filled when the menu opens. One instance serves the Actions pull-down's
    /// submenu and the Import item a user can add from Customize Toolbar, so the two cannot list
    /// different formats.
    internal let importFormatMenuDelegate = ImportFormatMenuDelegate()

    /// Kept for the same reason as the two above. The Actions menu is built on every open from the
    /// context the toolbar is pointed at, so it holds the toolbar weakly and asks it.
    internal private(set) lazy var actionsMenuDelegate = ConnectionActionsMenuDelegate(
        importFormats: importFormatMenuDelegate,
        context: { [weak self] in self?.currentContext() ?? ToolbarContext() }
    )

    override internal convenience init() {
        self.init(managedToolbar: ContextValidatedToolbar(identifier: Self.toolbarIdentifier))
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
        self.managedToolbar.centeredItemIdentifiers = [Self.connection, Self.database]
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
        refreshConnectionScopedItems()
        refreshContext(forcing: true)
        managedToolbar.validateVisibleItems()
    }

    func invalidate() {
        /// Window close reaches here rather than through `repoint`, and the panel surface is an
        /// independent floating `NSPanel` with no parent-child relationship to the window, so
        /// nothing else would take it down with the window that opened it. A window whose
        /// connection was released has no coordinator to reach it through.
        windowController?.switcherPresenter.dismiss()
        itemStateObservationGeneration += 1
        itemStateObservation = nil
        tabStateObservation = nil
        coordinator = nil
    }

    /// What a validation pass depends on beyond the responder chain. `validateVisibleItems()` is
    /// also what re-runs `StatefulToolbarItem.validate()`, so the safe-mode glyph tracks the level
    /// through the same channel rather than through an observer of its own.
    ///
    /// The tab manager is watched for the visibility key alone. It publishes on every edit to a
    /// tab, typing included, so its observer builds the key from its eight inputs, compares it and
    /// returns: no whole context, no validation pass and no write.
    private func observeItemState() {
        itemStateObservation = nil
        tabStateObservation = nil
        guard let coordinator else { return }
        let generation = itemStateObservationGeneration
        let coordinatorIdentifier = ObjectIdentifier(coordinator)
        /// Wakes for any change on the toolbar state rather than only the properties the items
        /// read. `validateVisibleItems()` is idempotent and builds one context for the whole pass,
        /// so the wider wake set costs a revalidation pass and nothing else.
        itemStateObservation = coordinator.toolbarState.onMainActorChange { [weak self] in
            guard let self, self.isObserving(generation, coordinatorIdentifier) else { return }
            self.refreshContext()
            self.managedToolbar.validateVisibleItems()
        }
        tabStateObservation = coordinator.tabManager.onMainActorChange { [weak self] in
            guard let self, self.isObserving(generation, coordinatorIdentifier) else { return }
            self.refreshContext()
        }
    }

    /// A callback queued before a repoint must not act on the connection that replaced its own.
    private func isObserving(_ generation: Int, _ coordinatorIdentifier: ObjectIdentifier) -> Bool {
        generation == itemStateObservationGeneration
            && coordinatorIdentifier == coordinator.map { ObjectIdentifier($0) }
    }

    /// Items carrying text derived from the connection. Validation cannot repoint them: a label is
    /// not part of what `validate()` reconsiders. They are pushed here instead.
    private func refreshConnectionScopedItems() {
        for item in allItems() {
            switch item.itemIdentifier {
            case Self.connection:
                /// The overflow entry carries the glyph too, and it is written once when the item
                /// is vended, so without this a clipped item kept the previous engine's icon.
                item.image = engineGlyph
                item.menuFormRepresentation?.setInformativeImage(engineGlyph)
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
            default:
                continue
            }
        }
    }

    /// The commit control says what its tab commits: Create Table on a definition tab, Apply
    /// Changes on Users & Roles, Save Changes everywhere else. The palette, the overflow menu and the
    /// tooltip all read the label, so all three move with it.
    ///
    /// Run only when the visibility key moves, because the verb is a function of the tab kind the
    /// key carries. It used to follow the staged change, which a Create Table draft raises and
    /// drops as it becomes valid and invalid, so the label flipped while the user typed and, with
    /// labels shown, every flip changed the item's width and reflowed the titlebar.
    private func refreshCommitVerb(for tabKind: TabType?) {
        let verb = ToolbarContextResolver.commitVerb(for: tabKind)
        for item in managedToolbar.items where item.itemIdentifier == Self.saveChanges && item.label != verb {
            apply(label: verb, to: item)
            updateShortcutDescription(verb, for: Self.saveChanges)
            applyShortcutBinding(to: item)
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

    // MARK: - Validation

    /// The context a validation question is answered from: the running pass's when there is one,
    /// and a fresh one otherwise.
    ///
    /// A pass asks once per visible item, and the context walks the coordinator for Add Row, Restore
    /// Previous Values and both navigation directions, so building it per item paid that walk once
    /// for every item on every pass AppKit runs. AppKit also asks outside a pass, measured on
    /// macOS 27: an item is validated once as it joins the toolbar, before any pass, and those
    /// questions take the fresh read.
    internal func validationContext() -> ToolbarContext {
        validationPassContext ?? currentContext()
    }

    /// Runs one validation pass over a context built once for all of it. A pass that starts inside
    /// another reuses the outer one's, because nothing can move between two items of one pass.
    internal func withinValidationPass(_ validate: () -> Void) {
        guard validationPassContext == nil else {
            validate()
            return
        }
        validationPassContext = currentContext()
        defer { validationPassContext = nil }
        validate()
    }

    // MARK: - Visibility

    /// Re-applies the titlebar's shape and the commit verb when the slow-moving half of the context
    /// has moved, and otherwise returns after building the key and comparing it.
    ///
    /// No whole context is built here. Visibility is a function of the key alone, so the coordinator
    /// walk the enablement questions need is never paid for a keystroke.
    ///
    /// `forcing` is for the moments the shape has to be re-established whatever the key says: a
    /// repoint to a different connection, and the toolbar first reaching its window. Every launch
    /// starts from an all-visible toolbar, measured, because `isHidden` is never persisted.
    internal func refreshContext(forcing: Bool = false) {
        let key = currentVisibilityKey()
        guard forcing || key != appliedVisibilityKey else { return }
        appliedVisibilityKey = key
        refreshCommitVerb(for: key.tabKind)
        apply(ToolbarContextResolver.visibility(for: key))
    }

    /// Writes the resolver's set onto the items the app placed, and never touches one the user
    /// added from the palette.
    ///
    /// `isHidden` and nothing else. `insertItem` and `removeItem` write the saved arrangement to
    /// disk on the spot, and every connection window shares this toolbar's identifier, so a context
    /// expressed that way would reach every other window and outlive the app.
    ///
    /// The validation pass is not optional. Measured on macOS 27, the `isHidden` setter runs no
    /// validation, and an item shown again keeps whatever `isEnabled` it had when it went away,
    /// through the same run-loop turn, the next one and 1.5s later, until something asks.
    ///
    /// Below macOS 15 there is no `isHidden`, so the full set stands and the contextual items dim.
    /// The record is left empty there, because it describes what the app hid and it hid nothing.
    internal func apply(_ visibility: ToolbarVisibility) {
        guard #available(macOS 15.0, *) else { return }
        self.visibility = visibility
        for item in managedToolbar.items where ToolbarContextResolver.hideableIdentifiers.contains(item.itemIdentifier) {
            item.isHidden = visibility.hides(item.itemIdentifier)
        }
        managedToolbar.validateVisibleItems()
    }

    /// One pass on the next turn rather than now: the item AppKit announces is not in
    /// `NSToolbar.items` until the notification returns. A burst of drops is still one pass.
    ///
    /// Only the item's own arrival needs it. A delegate that vends a fresh item every time hands
    /// back one that is visible, so the failure this covers is a hideable item that should be
    /// hidden staying visible until the next tab switch. With an instance cached across vends the
    /// failure is worse, measured: the palette hands back the same instance still hidden, and it
    /// takes a slot and draws nothing.
    internal func scheduleVisibilityReapply() {
        guard !isVisibilityReapplyScheduled else { return }
        isVisibilityReapplyScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isVisibilityReapplyScheduled = false
            self.apply(self.visibility)
        }
    }

    // MARK: - Identifiers

    /// `nonisolated` throughout: these are immutable strings that name a command, and
    /// `ToolbarContextResolver` reads them from off the main actor to answer which items a context
    /// shows. Isolating them to this class was incidental to the class being `@MainActor`.
    nonisolated static let connection = NSToolbarItem.Identifier("com.TablePro.toolbar.connection")
    nonisolated static let database = NSToolbarItem.Identifier("com.TablePro.toolbar.database")
    nonisolated static let refresh = NSToolbarItem.Identifier("com.TablePro.toolbar.refresh")
    nonisolated static let saveChanges = NSToolbarItem.Identifier("com.TablePro.toolbar.saveChanges")
    nonisolated static let addRow = NSToolbarItem.Identifier("com.TablePro.toolbar.addRow")
    nonisolated static let safeMode = NSToolbarItem.Identifier("com.TablePro.toolbar.safeMode")
    nonisolated static let quickSwitcher = NSToolbarItem.Identifier("com.TablePro.toolbar.quickSwitcher")
    nonisolated static let newTab = NSToolbarItem.Identifier("com.TablePro.toolbar.newTab")
    nonisolated static let previewSQL = NSToolbarItem.Identifier("com.TablePro.toolbar.previewSQL")
    nonisolated static let results = NSToolbarItem.Identifier("com.TablePro.toolbar.results")
    /// `.toggleInspector` is macOS 14. The identifier only has to be stable and unique, and
    /// AppKit's own inspector behaviour is not used here, so 13 gets an app-owned one.
    nonisolated static let inspector: NSToolbarItem.Identifier = {
        if #available(macOS 14.0, *) {
            return .toggleInspector
        }
        return NSToolbarItem.Identifier("com.TablePro.toolbar.inspector")
    }()
    nonisolated static let dashboard = NSToolbarItem.Identifier("com.TablePro.toolbar.dashboard")
    nonisolated static let history = NSToolbarItem.Identifier("com.TablePro.toolbar.history")
    nonisolated static let exportTables = NSToolbarItem.Identifier("com.TablePro.toolbar.export")
    nonisolated static let importTables = NSToolbarItem.Identifier("com.TablePro.toolbar.import")
    nonisolated static let restorePreviousValues = NSToolbarItem
        .Identifier("com.TablePro.toolbar.restorePreviousValues")
    nonisolated static let backForwardGroup = NSToolbarItem.Identifier("com.TablePro.toolbar.backForwardGroup")
    nonisolated static let navigateBack = NSToolbarItem.Identifier("com.TablePro.toolbar.navigateBack")
    nonisolated static let navigateForward = NSToolbarItem.Identifier("com.TablePro.toolbar.navigateForward")
    /// The pull-down that carries the long tail of a context's commands. One control whose menu
    /// changes with the tab, instead of one permanent titlebar slot per command.
    nonisolated static let actions = NSToolbarItem.Identifier("com.TablePro.toolbar.actions")

    // MARK: - NSToolbarDelegate

    /// Eight controls, and the zones are the panes. AppKit's own sidebar toggle stands alone ahead of
    /// `.sidebarTrackingSeparator`, so it lays out in the sidebar's titlebar strip and follows the
    /// divider; the connection and its container are centred; Refresh, the commit verb, the Actions
    /// pull-down and Safe Mode are the content run; the trailing-pane toggle closes the row.
    ///
    /// A tracking separator divides the toolbar into pane-aligned sections; it does not align the
    /// items inside one. Everything after `.inspectorTrackingSeparator` therefore lays out from
    /// that section's leading edge, which is the inspector divider, so the toggle walked inward as
    /// the pane opened and only looked right while the inspector was closed. The `.flexibleSpace`
    /// is what anchors it to the window's trailing edge, and it is the order Apple ships in
    /// WWDC23 session 10054. Keep the toggle last: ahead of the separator it lands in the content
    /// section and is wrong in both states.
    ///
    /// The centred pair are two top-level items, not two subitems of one group. Measured on macOS
    /// 27, `NSPopover.show(relativeTo:)` on a subitem raised `NSInvalidArgumentException` ("view has
    /// no window") whenever its group was hidden or clipped, which Swift cannot catch, while a
    /// top-level item raised in none of 16 presentations across the same states and across a
    /// Customize Toolbar visit: AppKit anchors it on the titlebar or on the clipped-items indicator
    /// instead. As two items they still centre as one adjacent pair, 249pt wide in a 1200pt window
    /// against the group's 257pt. Each carries a title rather than a label, so it still reads as
    /// words with the toolbar in icon-only mode, which is the shape Xcode gives its scheme and
    /// destination.
    ///
    /// Nothing here repeats the window title, which names the tab rather than the connection.
    /// `.inspectorTrackingSeparator` is macOS 14. Without it the divider does not track the
    /// inspector's edge; the items around it are unchanged.
    nonisolated internal static var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            connection,
            database,
            .flexibleSpace,
            refresh,
            saveChanges,
            actions,
            safeMode,
        ]
        if #available(macOS 14.0, *) {
            items.append(.inspectorTrackingSeparator)
        }
        items.append(contentsOf: [.flexibleSpace, inspector])
        return items
    }

    /// A proper superset of the default list: the commands a user can drag in from Customize
    /// Toolbar. Each one is also in the Actions pull-down or the menu bar, so the default set loses
    /// nothing by leaving it out, and an item added from here is the user's, so no context hides it.
    ///
    /// Back and Forward keep their group, because `isNavigational` is what gives the pair the
    /// leading-edge placement Finder and Safari use and two loose items cannot have it.
    ///
    /// Every identifier here must be one the delegate can build. Asked for one it cannot, the
    /// delegate answers nil, and with `autosavesConfiguration` on AppKit prunes it from the saved
    /// arrangement.
    nonisolated internal static let allowedItemIdentifiers: [NSToolbarItem.Identifier] = defaultItemIdentifiers + [
        backForwardGroup,
        previewSQL,
        results,
        exportTables,
        importTables,
        dashboard,
        history,
        addRow,
        restorePreviousValues,
        newTab,
        quickSwitcher,
    ]

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }
}
