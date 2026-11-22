import AppKit
import SwiftUI

@MainActor
internal protocol SettingsPaneContextProviding: AnyObject {
    func context(for pane: SettingsPane) -> SettingsPaneContext
}

// Keeps one hosting controller per visited pane while the window is open: rebuilding a pane on
// every sidebar click cost 136 to 374 ms and dropped its scroll position and @State.
@MainActor
internal final class SettingsDetailViewController: NSViewController {
    internal weak var provider: SettingsPaneContextProviding?
    private var hosts: [SettingsPane: NSHostingController<SettingsPaneHost>] = [:]
    internal private(set) var shownPane: SettingsPane?

    internal init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("SettingsDetailViewController does not support NSCoder init")
    }

    override internal func loadView() {
        view = NSView()
    }

    internal func host(for pane: SettingsPane) -> NSHostingController<SettingsPaneHost>? {
        hosts[pane]
    }

    internal func show(_ pane: SettingsPane) {
        guard isViewLoaded, let provider else { return }
        let existing = hosts[pane]
        guard pane != shownPane || existing == nil else { return }
        let host = existing ?? makeHost(for: provider.context(for: pane))
        for (other, hidden) in hosts where other != pane {
            // Hidden hosts leave the key view loop and the accessibility tree, and add nothing to a live resize.
            hidden.view.isHidden = true
            hidden.view.autoresizingMask = []
        }
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.width, .height]
        host.view.isHidden = false
        shownPane = pane
        // A show before the window is key counts when it becomes key, so opening counts once.
        if view.window?.isKeyWindow == true {
            provider.context(for: pane).visit.bump()
        }
    }

    internal func windowDidBecomeKey() {
        guard let shownPane, let provider else { return }
        provider.context(for: shownPane).visit.bump()
    }

    // After a close, so no pane observer or task outlives the window.
    internal func releaseHosts() {
        for host in hosts.values {
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        hosts.removeAll()
        shownPane = nil
    }

    private func makeHost(for context: SettingsPaneContext) -> NSHostingController<SettingsPaneHost> {
        let host = NSHostingController(rootView: SettingsPaneHost(context: context))
        // A split item's hosting controller fixes its fitting size as a required minimum unless this is cleared.
        host.sizingOptions = []
        if #available(macOS 14.0, *) {
            // The window title and toolbar belong to the shell; a pane's navigationTitle must not reach them.
            host.sceneBridgingOptions = []
        }
        addChild(host)
        host.view.frame = view.bounds
        view.addSubview(host.view)
        hosts[context.pane] = host
        return host
    }
}
