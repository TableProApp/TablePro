import AppKit

// An AppKit window, so the app needs no SwiftUI Settings scene (which would rewrite NSApp.mainMenu).
@MainActor
internal final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    // A new name: the old one holds 768 and 800 wide frames and heights shrunk by contentLayoutRect.
    internal static let frameAutosaveName = "settings-sidebar"
    internal static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    private static let preferredContentHeight: CGFloat = 700
    private static let screenMargin: CGFloat = 80

    private static var shared: SettingsWindowController?

    internal let split: SettingsSplitViewController

    internal static func present(_ request: SettingsRequest) {
        switch request {
        case .open(let location):
            present(location)
        case .revealPlugin(let pluginId):
            presentPlugin(revealing: pluginId)
        }
    }

    // Cmd-, on a visible window only brings it forward; a location navigates unless a sheet is up.
    internal static func present(_ location: SettingsLocation? = nil) {
        let controller = sharedController(opening: location)
        controller.prepareToShow(location)
        controller.showAndActivate()
    }

    // A loaded plugin opens its page; anything else asks the Extensions pane to find it once its list loads.
    internal static func presentPlugin(revealing pluginId: String?) {
        let location = pluginId.map { SettingsLocation(route: .plugin(id: $0)) } ?? .root(.plugins)
        let controller = sharedController(opening: location)
        if controller.prepareToShow(location), pluginId == nil {
            controller.split.model.requestPluginReveal(nil)
        }
        controller.showAndActivate()
    }

    private static func sharedController(opening location: SettingsLocation?) -> SettingsWindowController {
        if let shared { return shared }
        let controller = SettingsWindowController(
            registryClient: .shared,
            initial: .root(location?.pane ?? SettingsSplitViewController.persistedPane)
        )
        shared = controller
        return controller
    }

    // A defaulted parameter alone would let `SettingsWindowController()` resolve to an inherited init that builds no window.
    internal convenience init() {
        self.init(registryClient: .shared)
    }

    internal init(registryClient: RegistryClient, initial: SettingsLocation? = nil) {
        let split = SettingsSplitViewController(registryClient: registryClient, initial: initial)
        self.split = split

        // This init binds window.title to split.title, so the Window menu and VoiceOver read the page.
        let window = NSWindow(contentViewController: split)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.settings)
        window.styleMask = Self.styleMask
        window.keepsKeyViewLoopCurrent()
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert([.fullScreenNone, .fullScreenDisallowsTiling])
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.toolbar = split.toolbarController.makeToolbar()
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.initialFirstResponder = split.sidebar.tableView
        Self.applyFrame(to: window, autosaveName: SplitViewAutosaveName.current(Self.frameAutosaveName))

        super.init(window: window)
        window.delegate = self
        split.syncChrome()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoder init")
    }

    // Returns false when nothing navigated: an attached sheet, or no location for a window already on screen.
    @discardableResult
    internal func prepareToShow(_ location: SettingsLocation?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        if window.isVisible || window.isMiniaturized {
            guard let location else { return false }
            split.endEditing()
            split.navigate(to: location, recordsHistory: true)
            return true
        }
        split.navigate(to: location ?? .root(SettingsSplitViewController.persistedPane), recordsHistory: false)
        split.windowWillOpen()
        window.makeFirstResponder(split.sidebar.tableView)
        return true
    }

    private func showAndActivate() {
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    internal static func defaultContentSize(on screen: NSScreen?) -> NSSize {
        let available = (screen?.visibleFrame.height ?? 800) - screenMargin
        let height = max(SettingsSplitViewController.minimumContentSize.height, min(preferredContentHeight, available))
        return NSSize(width: SettingsSplitViewController.contentWidth, height: height)
    }

    // Reads the content size from contentRect(forFrameRect:): contentLayoutRect leaves out the toolbar
    // band, and writing it back shrank the window on every launch.
    internal static func applyFrame(to window: NSWindow, autosaveName: NSWindow.FrameAutosaveName?) {
        let width = SettingsSplitViewController.contentWidth
        let minimumHeight = SettingsSplitViewController.minimumContentSize.height
        let preferred = defaultContentSize(on: window.screen ?? NSScreen.main)
        window.setContentSize(preferred)

        // Restored before the size limits go on: AppKit clamps a restored frame to them, which hides an older width.
        var restored = false
        if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
            restored = window.setFrameUsingName(autosaveName)
        }
        let content = window.contentRect(forFrameRect: window.frame).size
        window.contentMinSize = SettingsSplitViewController.minimumContentSize
        window.contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if !restored || abs(content.width - width) > 0.5 {
            window.setContentSize(preferred)
            window.center()
        } else if content.height < minimumHeight {
            window.setContentSize(NSSize(width: width, height: minimumHeight))
        }
    }

    internal func windowShouldClose(_ sender: NSWindow) -> Bool {
        split.endEditing()
        return true
    }

    internal func windowWillClose(_ notification: Notification) {
        split.endEditing()
        split.windowDidClose()
        // Next turn, after AppKit finishes closing; a window reopened in the meantime keeps its panes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true, self.window?.isMiniaturized != true else { return }
            self.split.releasePanes()
        }
    }

    internal func windowDidBecomeKey(_ notification: Notification) {
        split.detail.windowDidBecomeKey()
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        split.endEditing()
    }

    @objc internal func navigateBack(_ sender: Any?) {
        split.goBack()
    }

    @objc internal func navigateForward(_ sender: Any?) {
        split.goForward()
    }

    @objc internal func performFind(_ sender: Any?) {
        split.focusSearch()
    }

    @objc internal func focusSidebarFilter(_ sender: Any?) {
        split.focusSidebarSearch()
    }
}

extension SettingsWindowController: NSMenuItemValidation {
    internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isFree = window?.attachedSheet == nil
        switch menuItem.action {
        case #selector(navigateBack(_:)):
            return isFree && split.model.canGoBack
        case #selector(navigateForward(_:)):
            return isFree && split.model.canGoForward
        case #selector(performFind(_:)), #selector(focusSidebarFilter(_:)):
            return isFree
        default:
            return true
        }
    }
}
