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
    private lazy var endpointMenus = CompareEndpointMenuBuilder(session: session) { [weak self] in
        self?.endpointsChanged()
    }

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

    internal func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .compareSource, .compareSwap, .compareTarget,
            .compareMode, .compareRun,
            .flexibleSpace,
            .compareGrouping, .compareOptions, .compareSearch,
            .compareGenerate, .compareApply
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
                prominent: true
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
                action: #selector(applyToTarget(_:))
            )
        case .compareOptions:
            return button(
                itemIdentifier,
                label: String(localized: "Options"),
                symbol: "slider.horizontal.3",
                action: #selector(showOptions(_:))
            )
        case .compareGrouping:
            return groupingItem(itemIdentifier)
        case .compareSearch:
            return searchItem(itemIdentifier)
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        prominent: Bool = false
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = self
        item.isBordered = true
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
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Compare")
        item.paletteLabel = String(localized: "What to Compare")
        item.toolTip = String(localized: "Compare structure or data")
        item.view = control
        return item
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

    private func searchItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Search")
        item.paletteLabel = String(localized: "Search")
        item.toolTip = String(localized: "Filter results by name")
        item.searchField.sendsWholeSearchString = false
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        return item
    }

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

    @objc internal func showOptions(_ sender: Any?) {
        presentOptionsPopover(from: sender)
    }

    @objc internal func stopComparison(_ sender: Any?) {
        session.cancelRunningWork()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard CompareSyncMode.allCases.indices.contains(index) else { return }
        session.mode = CompareSyncMode.allCases[index]
        session.resetComparison()
    }

    @objc private func groupingChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let grouping = CompareGrouping(rawValue: raw) else { return }
        session.grouping = grouping
        window?.toolbar?.items
            .compactMap { $0 as? NSMenuToolbarItem }
            .forEach { menuItem in
                menuItem.menu.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
            }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        session.searchText = sender.stringValue
    }

    private func endpointsChanged() {
        session.resetComparison()
        window?.subtitle = session.directionSentence ?? ""
    }

    // MARK: - Validation

    /// Every toolbar item is also a menu-bar command, so both validate here. The HIG requires the
    /// menu-bar mirror; this is the single place that decides whether either is available.
    internal func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(runComparison(_:)):
            return session.canCompare
        case #selector(generateScript(_:)):
            return session.canBuildScript
        case #selector(applyToTarget(_:)):
            return session.canApply
        case #selector(swapEndpoints(_:)):
            return session.canSwap && !session.isBusy
        case #selector(stopComparison(_:)):
            return session.isBusy
        case #selector(showOptions(_:)):
            return true
        default:
            return true
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

    private func presentOptionsPopover(from sender: Any?) {
        guard let window else { return }
        let content = NSHostingController(rootView: CompareOptionsView(session: session).environment(\.appServices, .live))
        content.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.behavior = .transient
        let anchor = (sender as? NSToolbarItem)?.view
            ?? window.toolbar?.items.first { $0.itemIdentifier == .compareOptions }?.view
        guard let anchor else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
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
