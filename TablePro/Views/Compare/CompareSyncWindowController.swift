//
//  CompareSyncWindowController.swift
//  TablePro
//
//  The Compare & Sync window.
//
//  Shaped like FileMerge's result window rather than an assistant: one
//  persistent window with a customizable, autosaving toolbar, which is what
//  Apple ships for a comparison the user re-runs. The four-step wizard this
//  replaces had no toolbar, so it grew a numbered step header and a bottom
//  action bar, both of which the HIG names directly: "Avoid creating custom
//  window UI" and "Avoid putting critical information or actions in a bottom
//  bar, because people often relocate a window in a way that hides its bottom
//  edge."
//
//  The toolbar is attached in `init`, after the session exists, because a
//  delegate that returns nil for an item while `autosavesConfiguration` is on
//  permanently prunes that item from the saved configuration on disk.
//

import AppKit
import SwiftUI

internal extension NSToolbarItem.Identifier {
    static let compareSaved = NSToolbarItem.Identifier("com.TablePro.compare.saved")
    static let compareSource = NSToolbarItem.Identifier("com.TablePro.compare.source")
    static let compareSwap = NSToolbarItem.Identifier("com.TablePro.compare.swap")
    static let compareTarget = NSToolbarItem.Identifier("com.TablePro.compare.target")
    static let compareMode = NSToolbarItem.Identifier("com.TablePro.compare.mode")
    static let compareRun = NSToolbarItem.Identifier("com.TablePro.compare.run")
    static let compareOptions = NSToolbarItem.Identifier("com.TablePro.compare.options")
    static let compareGrouping = NSToolbarItem.Identifier("com.TablePro.compare.grouping")
    static let compareSearch = NSToolbarItem.Identifier("com.TablePro.compare.search")
    static let compareGenerate = NSToolbarItem.Identifier("com.TablePro.compare.generate")
    static let compareApply = NSToolbarItem.Identifier("com.TablePro.compare.apply")
}

@MainActor
internal final class CompareSyncWindowController: NSWindowController,
    NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSUserInterfaceValidations {
    private static var controllers: [UUID?: CompareSyncWindowController] = [:]

    private let session = CompareSyncSession()
    private lazy var runner = CompareRunner(session: session)
    private lazy var endpointMenus = CompareEndpointToolbarController(
        session: session,
        windowProvider: { [weak self] in self?.window }
    ) { [weak self] in
        self?.endpointsChanged()
    }
    private weak var modeControl: NSSegmentedControl?
    private weak var searchToolbarItem: NSSearchToolbarItem?
    private var renderedEndpoints: String?

    internal static func present(prefillSource connectionId: UUID?) {
        let controller = controllers[connectionId] ?? CompareSyncWindowController(prefillSource: connectionId)
        controllers[connectionId] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private init(prefillSource connectionId: UUID?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 460)
        window.title = String(localized: "Compare & Sync")
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.compareSync)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)

        applyPrefill(connectionId)
        window.contentViewController = makeContentController()
        window.delegate = self
        window.applyAutosaveName(WindowIdentifier.compareSync)
        installToolbar(on: window)
        installStatusStrip(on: window)
        /// A restored data comparison has a pair but no table list, and the list is what the mode
        /// needs before anything can be ticked. Routed through the one chrome refresh so the
        /// subtitle, the picker titles and the load all follow the same rule.
        refreshEndpointChrome()
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func makeContentController() -> NSViewController {
        let content = CompareWindowContentView(
            session: session,
            onCompare: { [weak self] in self?.runner.compare() },
            onGenerateScript: { [weak self] in self?.runner.buildScript() },
            onApply: { [weak self] in self?.presentApplySheet() }
        )
        .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        /// A standalone window wants the content's minimum to become the window's, unlike a split
        /// pane's host, where the same minimum would pin the window's dividers.
        hosting.sizingOptions = [.minSize]
        return hosting
    }

    /// The window opens where it was left, which is what makes running the same comparison again
    /// one press of Compare rather than a walk back through both pickers, the mode and the options.
    /// A connection the window was opened *from* still wins the source, because that is what the
    /// user just pointed at.
    private func applyPrefill(_ connectionId: UUID?) {
        let prefilled = connectionId.flatMap { id -> DatabaseEndpoint? in
            let connections = ConnectionStorage.shared.loadConnections()
            guard let match = connections.first(where: { $0.id == id }) else { return nil }
            return DatabaseEndpoint.from(connection: match)
        }
        guard let setup = CompareSyncProfileStorage.shared.lastSetup() else {
            session.source = prefilled
            return
        }
        session.restore(setup, keepingSource: prefilled)
    }

    /// The strip belongs to the window frame, not to the content: it reports what the window is
    /// doing, so it stays put while the panes scroll and it is not a row the split view has to
    /// budget for. `NSTitlebarAccessoryViewController`'s `.bottom` means the bottom of the
    /// *titlebar*, which is exactly this position, directly under the toolbar.
    private func installStatusStrip(on window: NSWindow) {
        let hosting = NSHostingController(rootView: CompareStatusStrip(session: session))
        hosting.sizingOptions = [.preferredContentSize]
        let accessory = NSTitlebarAccessoryViewController()
        /// The accessory owns the hosting controller, not just its view. Handing over the bare view
        /// leaves nothing retaining the controller, and a deallocated `NSHostingController` stops
        /// updating the SwiftUI it was built from.
        accessory.addChild(hosting)
        accessory.view = hosting.view
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - Toolbar

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "com.TablePro.CompareSyncToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        insertSavedComparisonsItemOnce(into: toolbar)
    }

    /// `autosavesConfiguration` restores the identifiers a configuration was saved with, so an item
    /// added to the defaults afterwards never appears for anyone who already has one. Inserted once,
    /// recorded once, and never again, so a user who then removes it keeps it removed.
    private func insertSavedComparisonsItemOnce(into toolbar: NSToolbar) {
        let defaults = AppStorageEnvironment.shared.defaults
        guard !defaults.bool(forKey: Self.savedComparisonsInsertedKey) else { return }
        defaults.set(true, forKey: Self.savedComparisonsInsertedKey)
        guard !toolbar.items.contains(where: { $0.itemIdentifier == .compareSaved }) else { return }
        toolbar.insertItem(withItemIdentifier: .compareSaved, at: 0)
    }

    private static let savedComparisonsInsertedKey = "compareSyncToolbarHasSavedComparisonsItem"

    /// The HIG's item grouping: what the window is about on the leading edge, view controls in the
    /// middle, and the actions on the trailing edge, where "items on the trailing edge remain
    /// visible at all window sizes" and where the one primary action belongs. Compare used to sit
    /// on the leading edge beside the pickers, which put the primary action in the group reserved
    /// for identity and made it the first thing to be clipped.
    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .compareSaved, .compareSource, .compareSwap, .compareTarget,
            .flexibleSpace,
            .compareMode, .compareGrouping, .compareOptions, .compareSearch,
            .space,
            .compareGenerate, .compareApply, .compareRun
        ]
    }

    internal func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .sidebarTrackingSeparator]
    }

    internal func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .compareSaved:
            return savedComparisonsItem(itemIdentifier)
        case .compareSource:
            return endpointMenus.item(for: .source, identifier: itemIdentifier)
        case .compareTarget:
            return endpointMenus.item(for: .target, identifier: itemIdentifier)
        case .compareSwap:
            return button(
                itemIdentifier,
                label: String(localized: "Swap"),
                symbol: "arrow.left.arrow.right",
                action: #selector(swapEndpoints(_:))
            )
        case .compareMode:
            return modeItem(itemIdentifier)
        case .compareRun:
            return button(
                itemIdentifier,
                label: String(localized: "Compare"),
                symbol: "arrow.triangle.2.circlepath",
                action: #selector(runComparison(_:)),
                prominent: true,
                visibility: .high
            )
        case .compareGenerate:
            return button(
                itemIdentifier,
                label: String(localized: "Generate Script"),
                symbol: "doc.text",
                action: #selector(generateScript(_:))
            )
        case .compareApply:
            return button(
                itemIdentifier,
                label: String(localized: "Apply…"),
                symbol: "square.and.arrow.down.on.square",
                action: #selector(applyToTarget(_:)),
                visibility: .high
            )
        case .compareOptions:
            return button(
                itemIdentifier,
                label: String(localized: "Options"),
                symbol: "slider.horizontal.3",
                action: #selector(showOptions(_:)),
                visibility: .low
            )
        case .compareGrouping:
            return groupingItem(itemIdentifier)
        case .compareSearch:
            return searchItem(itemIdentifier)
        default:
            return nil
        }
    }

    /// `toolTip` is deliberately not the item's own label. The HIG says to "consider offering
    /// context-sensitive tooltips" with "different text for a control's different states" and, in
    /// the same breath, to "avoid repeating a control's name in its tooltip". Repeating the name is
    /// what this did, so a disabled Apply explained nothing. `validateUserInterfaceItem` refreshes
    /// the tip from the session's reason every time AppKit validates.
    private func button(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        prominent: Bool = false,
        visibility: NSToolbarItem.VisibilityPriority = .standard
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = self
        item.isBordered = true
        item.visibilityPriority = visibility
        item.menuFormRepresentation = NSMenuItem(title: label, action: action, keyEquivalent: "")
        item.menuFormRepresentation?.target = self
        /// macOS 26 is the first release with a prominent toolbar item style. Before it, weight
        /// comes from position and grouping alone: a hand-tinted bezel would be this app inventing
        /// chrome, which is what the rebuild set out to remove.
        if prominent, #available(macOS 26.0, *) {
            item.style = .prominent
        }
        return item
    }

    private func modeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let control = NSSegmentedControl(
            labels: CompareSyncMode.allCases.map { $0.displayName },
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        control.selectedSegment = CompareSyncMode.allCases.firstIndex(of: session.mode) ?? 0
        modeControl = control
        let item = NSToolbarItem(itemIdentifier: identifier)
        /// Not "Compare": the button beside it already carries that label, and two toolbar items
        /// reading the same word cannot be told apart in the overflow menu or by VoiceOver.
        item.label = String(localized: "Mode")
        item.paletteLabel = String(localized: "What to Compare")
        item.toolTip = String(localized: "Compare structure or data")
        item.view = control
        /// A view-backed item collapses to an inert titled entry in the overflow menu unless it
        /// supplies its own. Without this, narrowing the window took Structure and Data away with
        /// no way to switch back.
        let overflow = NSMenuItem(title: String(localized: "Compare"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in CompareSyncMode.allCases {
            let entry = NSMenuItem(title: mode.displayName, action: #selector(modePicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = session.mode == mode ? .on : .off
            submenu.addItem(entry)
        }
        overflow.submenu = submenu
        item.menuFormRepresentation = overflow
        return item
    }

    /// The segmented control is seeded once at construction, so anything that writes `session.mode`
    /// from elsewhere, loading a saved comparison for instance, used to leave the toolbar showing
    /// the other mode while the panes had already switched.
    private func syncModeControl() {
        guard let index = CompareSyncMode.allCases.firstIndex(of: session.mode) else { return }
        if modeControl?.selectedSegment != index {
            modeControl?.selectedSegment = index
        }
        modeControl?.isEnabled = !session.isBusy
    }

    /// Loading a saved comparison is the one action that sets both endpoints at once, so it sits on
    /// the leading edge with them rather than among the view controls. Its menu is built by
    /// `menuNeedsUpdate` rather than at construction, because a comparison saved a moment ago has
    /// to be in the list without the window being reopened.
    private func savedComparisonsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Comparisons")
        item.paletteLabel = String(localized: "Saved Comparisons")
        item.toolTip = String(localized: "Load a saved source, target and options")
        item.image = NSImage(
            systemSymbolName: "list.star",
            accessibilityDescription: String(localized: "Saved Comparisons")
        )
        item.showsIndicator = true
        let menu = NSMenu()
        /// Identified rather than remembered. Customize Toolbar asks the delegate for more copies
        /// of an item with `willBeInsertedIntoToolbar` false, so a stored reference ends up naming
        /// a palette copy that was thrown away, and the menu the user actually opens never matches
        /// it. The same trap `refreshTitles` documents for the endpoint items.
        menu.identifier = Self.savedComparisonsMenuIdentifier
        menu.delegate = self
        item.menu = menu
        return item
    }

    private static let savedComparisonsMenuIdentifier =
        NSUserInterfaceItemIdentifier("com.TablePro.compare.savedMenu")

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == Self.savedComparisonsMenuIdentifier else { return }
        menu.removeAllItems()
        for profile in session.savedProfiles {
            let entry = NSMenuItem(title: profile.name, action: #selector(loadProfile(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile.id
            entry.toolTip = describe(profile)
            menu.addItem(entry)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let save = NSMenuItem(
            title: String(localized: "Save Comparison…"),
            action: #selector(saveComparison(_:)),
            keyEquivalent: ""
        )
        save.target = self
        menu.addItem(save)
    }

    private func describe(_ profile: CompareSyncProfile) -> String {
        String(
            format: String(localized: "%1$@ → %2$@, %3$@"),
            profile.source.database, profile.target.database, profile.mode.displayName
        )
    }

    @objc private func loadProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = session.savedProfiles.first(where: { $0.id == id }) else { return }
        guard session.apply(profile) else { return }
        refreshEndpointChrome()
    }

    /// The name is asked for in an alert rather than in the Options popover, because a user who has
    /// just set up a pair should not have to find a text field in a settings sheet to keep it.
    @objc internal func saveComparison(_ sender: Any?) {
        guard let window, session.source != nil, session.target != nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save this comparison")
        alert.informativeText = String(
            localized: "The source, the target, the mode and the options come back when you load it."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self.session.saveProfile(named: field.stringValue) }
        }
        /// The accessory is only in the window once the sheet is up, so focus is asked for after.
        DispatchQueue.main.async { alert.window.makeFirstResponder(field) }
    }

    private func groupingItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Group By")
        item.paletteLabel = String(localized: "Group By")
        item.toolTip = String(localized: "Group results by difference or object type")
        item.image = NSImage(
            systemSymbolName: "list.bullet.indent",
            accessibilityDescription: String(localized: "Group By")
        )
        item.showsIndicator = true
        let menu = NSMenu()
        for grouping in CompareGrouping.allCases {
            let entry = NSMenuItem(title: grouping.title, action: #selector(groupingChanged(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = grouping.rawValue
            entry.state = session.grouping == grouping ? .on : .off
            menu.addItem(entry)
        }
        item.menu = menu
        return item
    }

    /// `NSSearchToolbarItem` stretches past `preferredWidthForSearchField` to absorb whatever slack
    /// the toolbar has: measured at 325pt in a 1400pt window against a preferred 240, which is why
    /// the field swallowed a third of the toolbar. The preferred width is documented as the width
    /// it takes "whenever it gets the keyboard focus", not a cap, so the cap has to be a real
    /// constraint on the field. `NSSearchToolbarItem.h`: "If specifying custom width constraints to
    /// the search field, they should not conflict with this value", so both are the same number.
    ///
    /// The field is configured before it is assigned, which is the order the header asks for:
    /// "While inside the toolbar item, the field properties and layout constraints are managed by
    /// the item. The field should be configured before assigned."
    private func searchItem(_ identifier: NSToolbarItem.Identifier) -> NSSearchToolbarItem {
        let field = NSSearchField()
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.placeholderString = String(localized: "Filter by name")
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.stringValue = session.searchText

        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Filter")
        item.paletteLabel = String(localized: "Filter")
        item.toolTip = String(localized: "Show only the objects whose name contains this text")
        item.searchField = field
        item.preferredWidthForSearchField = Self.searchFieldWidth
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.searchFieldWidth).isActive = true
        item.visibilityPriority = .low
        searchToolbarItem = item
        return item
    }

    private static let searchFieldWidth: CGFloat = 220

    // MARK: - Actions

    @objc internal func runComparison(_ sender: Any?) {
        runner.compare()
    }

    @objc internal func generateScript(_ sender: Any?) {
        runner.buildScript()
    }

    @objc internal func applyToTarget(_ sender: Any?) {
        presentApplySheet()
    }

    @objc internal func swapEndpoints(_ sender: Any?) {
        session.swapEndpoints()
        endpointsChanged()
    }

    /// Every path that changes an endpoint funnels here, because the toolbar's Source and Target
    /// titles are rendered once and do not observe the session. Swap used to leave them naming the
    /// old pair while the strip and the subtitle had already flipped, so the toolbar pointed at the
    /// wrong database as the one about to be written to.
    private func endpointsChanged() {
        session.resetComparison()
        session.clearSetupErrorIfResolved()
        refreshEndpointChrome()
    }

    /// The Source and Target titles and the window subtitle are rendered rather than observed, so
    /// anything that sets an endpoint from outside this controller, loading a saved comparison from
    /// the Options popover for one, used to leave the toolbar naming the old pair. Validation runs
    /// on every event loop turn and this writes only when the pair actually changed, so the chrome
    /// follows the session wherever the change came from.
    private func refreshEndpointChrome() {
        /// Keyed on the setup generation as well as the pair, because loading a saved comparison
        /// for the pair already on screen, or changing a matching option, resets the session
        /// without changing either endpoint id. Without the generation the promised reload never
        /// started and the pane sat empty.
        let rendered = "\(session.source?.id ?? "")\u{1F}\(session.target?.id ?? "")\u{1F}\(session.setupGeneration)"
        guard renderedEndpoints != rendered else { return }
        renderedEndpoints = rendered
        endpointMenus.refreshTitles()
        updateSubtitle()
        syncModeControl()
        /// A new pair in data mode needs its table list, whoever set the pair. Loading a saved
        /// comparison from the Options popover reaches the session without passing through this
        /// controller at all, so the list has to follow the pair rather than the call site, and one
        /// call site rather than several is what keeps two reads of it from starting at once.
        runner.loadDataPlans()
    }

    @objc internal func showOptions(_ sender: Any?) {
        presentOptionsPopover(from: sender)
    }

    @objc internal func stopComparison(_ sender: Any?) {
        session.cancelRunningWork()
    }

    /// Edit > Find > Find… already owns Command F and routes by nil target, so the Compare window
    /// answers that command rather than declaring a second binding for the same idea: two menu
    /// items sharing a key equivalent leaves one of them permanently dead.
    /// `beginSearchInteraction` is AppKit's own entry point, and it works even once the item has
    /// been clipped into the overflow menu.
    @objc internal func performFind(_ sender: Any?) {
        searchToolbarItem?.beginSearchInteraction()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard CompareSyncMode.allCases.indices.contains(index) else { return }
        adopt(CompareSyncMode.allCases[index])
    }

    @objc private func modePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CompareSyncMode(rawValue: raw) else { return }
        adopt(mode)
    }

    private func adopt(_ mode: CompareSyncMode) {
        guard session.mode != mode else { return }
        session.mode = mode
        session.resetComparison()
        refreshEndpointChrome()
    }

    /// Only the Group By menu, found by identifier. Walking every `NSMenuToolbarItem` also reached
    /// the Source and Target popups and rewrote their checkmarks from a grouping value.
    @objc private func groupingChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let grouping = CompareGrouping(rawValue: raw) else { return }
        session.grouping = grouping
        let item = window?.toolbar?.items.first { $0.itemIdentifier == .compareGrouping }
        guard let menu = (item as? NSMenuToolbarItem)?.menu else { return }
        for entry in menu.items {
            entry.state = (entry.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        session.searchText = sender.stringValue
    }

    /// `NSWindow.subtitle` is "a secondary line of text that appears in the title bar": contextual
    /// identity for the window, on the row it shares with toolbar items. It carried the whole
    /// direction sentence, which restated the status strip word for word and spent titlebar width
    /// the HIG reserves for controls. `WindowTitleResolver`, the app's own rule for every other
    /// window, puts the compact scope binding there and nothing else.
    private func updateSubtitle() {
        guard let source = session.source, let target = session.target else {
            window?.subtitle = ""
            return
        }
        window?.subtitle = String(
            format: String(localized: "%1$@ → %2$@"),
            source.scopeDescription, target.scopeDescription
        )
    }

    // MARK: - Validation

    /// Every toolbar item is also a menu-bar command, so both validate here. The HIG requires the
    /// menu-bar mirror; this is the single place that decides whether either is available.
    internal func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let reason = disabledReason(for: item.action)
        describe(item, reason: reason)
        syncModeControl()
        refreshEndpointChrome()
        return reason == nil
    }

    private func disabledReason(for action: Selector?) -> String? {
        switch action {
        case #selector(runComparison(_:)):
            return session.compareDisabledReason
        case #selector(generateScript(_:)):
            return session.scriptDisabledReason
        case #selector(applyToTarget(_:)):
            return session.applyDisabledReason
        case #selector(swapEndpoints(_:)):
            guard session.canSwap else { return String(localized: "Choose a source or a target first.") }
            return session.isBusy ? String(localized: "A comparison is already running.") : nil
        case #selector(stopComparison(_:)):
            return session.isBusy ? nil : String(localized: "Nothing is running.")
        case #selector(performFind(_:)):
            return searchToolbarItem == nil ? String(localized: "The filter field is not in the toolbar.") : nil
        case #selector(saveComparison(_:)):
            if session.isBusy { return String(localized: "A run is already in progress.") }
            guard session.source != nil, session.target != nil else {
                return String(localized: "Choose a source and a target first.")
            }
            return nil
        default:
            return nil
        }
    }

    /// The tooltip is the reason when there is one and the item's purpose when there is not, which
    /// is what the HIG means by a tooltip carrying "different text for a control's different
    /// states" rather than repeating the control's name.
    private func describe(_ item: any NSValidatedUserInterfaceItem, reason: String?) {
        guard let toolbarItem = item as? NSToolbarItem else { return }
        /// An identifier with no purpose of its own keeps whatever tooltip it was built with. The
        /// Source and Target items carry the unshortened scope there, and blanking it would undo
        /// the only place the full path is still readable.
        guard let text = reason ?? purpose(of: toolbarItem.itemIdentifier) else { return }
        toolbarItem.toolTip = text
    }

    private func purpose(of identifier: NSToolbarItem.Identifier) -> String? {
        switch identifier {
        case .compareRun: return String(localized: "Compare the two databases")
        case .compareGenerate: return String(localized: "Build the SQL that brings the target in line")
        case .compareApply: return String(localized: "Run the script against the target")
        case .compareSwap: return String(localized: "Make the target the source and the source the target")
        case .compareOptions: return String(localized: "What to compare, and how")
        default: return nil
        }
    }

    // MARK: - Sheets

    /// Apply builds the script itself when there is not one yet, so the sheet that reviews it is
    /// one press from a finished comparison. Generate Script stays for a user who wants to read the
    /// SQL, or copy it, without going near the sheet.
    private func presentApplySheet() {
        guard session.canApply else { return }
        guard session.statements.isEmpty else { return showApplySheet() }
        /// The pickers stay live while the script builds, so the setup can move under the build.
        /// Opening the sheet then would label it with the new target and offer the old script to
        /// run against it. The generation the build started at is what says whether that happened.
        let generation = session.setupGeneration
        Task { [runner] in
            guard await runner.buildScriptIfNeeded(), session.isCurrent(generation) else { return }
            showApplySheet()
        }
    }

    private func showApplySheet() {
        guard let window else { return }
        let sheet = EscapeDismissingHostingController(
            rootView: CompareApplySheetView(session: session) { [weak self] choice in
                guard let self else { return }
                self.dismissSheet()
                guard choice == .apply else { return }
                self.runner.apply()
            }
            .environment(\.appServices, .live)
        )
        sheet.sizingOptions = []
        sheet.preferredContentSize = NSSize(width: 640, height: 520)
        window.contentViewController?.presentAsSheet(sheet)
    }

    /// The anchor used to be `(sender as? NSToolbarItem)?.view`, which is nil for a plain
    /// image-and-action item, so the guard below it returned every time and the whole options
    /// popover was unreachable. `PopoverPresenter` takes the item itself, and AppKit resolves the
    /// anchor even when the item has been clipped into the overflow menu.
    private func presentOptionsPopover(from sender: Any?) {
        let item = (sender as? NSToolbarItem)
            ?? window?.toolbar?.items.first { $0.itemIdentifier == .compareOptions }
        guard let item else { return }
        PopoverPresenter.show(
            relativeTo: item,
            contentSize: NSSize(width: 420, height: 520)
        ) { _ in
            CompareOptionsView(session: self.session)
                .environment(\.appServices, .live)
        }
    }

    private func dismissSheet() {
        guard let sheet = window?.contentViewController?.presentedViewControllers?.last else { return }
        window?.contentViewController?.dismiss(sheet)
    }

    // MARK: - NSWindowDelegate

    /// The controller owns the window's delegate, so the close guard lives here. The view this
    /// replaces installed a proxy delegate from a background `NSViewRepresentable` to answer this
    /// one message, which meant a SwiftUI view reaching around AppKit's ownership to do it.
    internal func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.activity == .applying else { return true }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "A sync is still running")
        alert.informativeText = String(
            localized: "Closing now stops the run between statements. Statements that already ran stay applied."
        )
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Stop and Close"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }

        session.cancelRunningWork()
        return true
    }

    internal func windowWillClose(_ notification: Notification) {
        session.cancelRunningWork()
        Self.controllers = Self.controllers.filter { $0.value !== self }
    }
}

/// Cancel is the sheet's default button, per the HIG's rule for a destructive confirmation, so it
/// carries the Return shortcut and cannot also carry Escape. A sheet still has to answer Escape,
/// which is what `cancelOperation` is.
@MainActor
private final class EscapeDismissingHostingController<Content: View>: NSHostingController<Content> {
    override func cancelOperation(_ sender: Any?) {
        presentingViewController?.dismiss(self)
    }
}
