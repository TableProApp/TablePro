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
    NSWindowDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
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

    private func applyPrefill(_ connectionId: UUID?) {
        guard let connectionId else { return }
        let connections = ConnectionStorage.shared.loadConnections()
        guard let match = connections.first(where: { $0.id == connectionId }) else { return }
        session.source = CompareSyncEndpoint.from(connection: match)
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
    }

    /// The HIG's item grouping: what the window is about on the leading edge, view controls in the
    /// middle, and the actions on the trailing edge, where "items on the trailing edge remain
    /// visible at all window sizes" and where the one primary action belongs. Compare used to sit
    /// on the leading edge beside the pickers, which put the primary action in the group reserved
    /// for identity and made it the first thing to be clipped.
    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .compareSource, .compareSwap, .compareTarget,
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
        endpointMenus.refreshTitles()
        updateSubtitle()
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
        syncModeControl()
        endpointMenus.refreshTitles()
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

    private func presentApplySheet() {
        guard let window, session.canApply else { return }
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
