import AppKit
import os

// Settings is chrome: no theme slot and no ThemeBackdropState, only the system sidebar material
// and each Form's own background.
@MainActor
internal final class SettingsSplitViewController: NSSplitViewController, SettingsPaneContextProviding {
    internal static let sidebarWidth: CGFloat = 220
    internal static let detailWidth: CGFloat = 520
    internal static let contentWidth: CGFloat = sidebarWidth + detailWidth
    internal static let minimumContentSize = NSSize(width: contentWidth, height: 480)

    private static let logger = Logger(subsystem: "com.TablePro", category: "SettingsWindow")

    internal let model: SettingsNavigationModel
    internal let toolbarController = SettingsWindowToolbar()
    internal let models = SettingsWindowModels()
    internal let sidebar: SettingsSidebarViewController
    internal let detail = SettingsDetailViewController()

    private let registryClient: RegistryClient
    private let titles: SettingsTitleResolver
    private var contexts: [SettingsPane: SettingsPaneContext] = [:]
    private var panesReleased = false

    internal init(
        registryClient: RegistryClient = .shared,
        initial: SettingsLocation? = nil,
        titles: SettingsTitleResolver = SettingsTitleResolver()
    ) {
        self.registryClient = registryClient
        self.titles = titles
        let start = initial ?? .root(Self.persistedPane)
        self.model = SettingsNavigationModel(
            initial: start,
            isRouteAvailable: { titles.isAvailable($0) },
            titleResolver: { titles.title(for: $0) }
        )
        self.sidebar = SettingsSidebarViewController(location: start)
        super.init(nibName: nil, bundle: nil)
        detail.provider = self
        title = model.title

        model.onLocationChange = { [weak self] _ in self?.syncChrome() }
        model.onUserPick = { Self.persist($0) }
        sidebar.searchEntries = { titles.searchEntries }
        sidebar.onSelectPane = { [weak self] pane in
            self?.endEditing()
            self?.model.select(pane)
        }
        sidebar.onOpenLocation = { [weak self] location in
            self?.endEditing()
            self?.model.open(location, recordsHistory: true)
            // A search result is still a pick in the sidebar, so it sets the last-used pane like a row click.
            Self.persist(location.pane)
        }
        toolbarController.onBack = { [weak self] in self?.goBack() }
        toolbarController.onForward = { [weak self] in self?.goForward() }
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("SettingsSplitViewController does not support NSCoder init")
    }

    internal static var persistedPane: SettingsPane {
        let stored = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
        return stored.flatMap(SettingsPane.init(rawValue:)) ?? SettingsNavigation.defaultPane
    }

    private static func persist(_ pane: SettingsPane) {
        AppStorageEnvironment.shared.defaults.set(pane.rawValue, forKey: PreferenceKeys.selectedSettingsPane.name)
    }

    override internal func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detail)
        // The divider comes out of the fixed width, so the detail minimum leaves room for it.
        detailItem.minimumThickness = Self.detailWidth - splitView.dividerThickness
        detailItem.holdingPriority = .splitPaneHolding
        addSplitViewItem(detailItem)

        syncChrome()
    }

    // MARK: - Navigation

    internal func navigate(to pane: SettingsPane) {
        navigate(to: .root(pane), recordsHistory: true)
    }

    internal func navigate(to location: SettingsLocation, recordsHistory: Bool) {
        _ = view
        model.open(location, recordsHistory: recordsHistory)
    }

    internal func goBack() {
        endEditing()
        model.goBack()
    }

    internal func goForward() {
        endEditing()
        model.goForward()
    }

    // Commits a field being edited before the shell moves away from it; AppKit ends editing on resign.
    internal func endEditing() {
        guard let window = view.window, window.firstResponder is NSTextView else { return }
        window.makeFirstResponder(nil)
    }

    internal func focusSearch() {
        guard !toolbarController.focusFilter() else { return }
        focusSidebarSearch()
    }

    internal func focusSidebarSearch() {
        view.window?.makeFirstResponder(sidebar.searchField)
    }

    // MARK: - Window lifetime

    internal func windowWillOpen() {
        panesReleased = false
        titles.startObserving { [weak self] in self?.namesDidChange() }
        model.refresh()
        syncChrome()
    }

    internal func windowDidClose() {
        titles.stopObserving()
        sidebar.clearSearch()
        model.resetHistory()
    }

    internal func releasePanes() {
        panesReleased = true
        detail.releaseHosts()
        contexts.removeAll()
    }

    private func namesDidChange() {
        model.refresh()
        sidebar.reloadSearchResults()
    }

    // MARK: - Chrome

    // The one place a location change reaches the window: title, toolbar, sidebar row and detail host.
    internal func syncChrome() {
        let location = model.location
        title = model.title
        toolbarController.update(canGoBack: model.canGoBack, canGoForward: model.canGoForward)
        guard isViewLoaded else { return }
        sidebar.reflect(location)
        guard !panesReleased else { return }
        toolbarController.showFilter(for: location.pane, filter: filter(for: location.pane))
        detail.show(location.pane)
    }

    private func filter(for pane: SettingsPane) -> SettingsPaneFilter? {
        guard SettingsPaneContext.filtersItsList(pane) else { return nil }
        return context(for: pane).filter
    }

    internal func context(for pane: SettingsPane) -> SettingsPaneContext {
        if let context = contexts[pane] { return context }
        let context = SettingsPaneContext(
            pane: pane,
            settings: .shared,
            navigation: model,
            models: models,
            registryClient: registryClient,
            presentError: { [weak self] title, message in self?.presentError(title: title, message: message) }
        )
        contexts[pane] = context
        return context
    }

    private func presentError(title: String, message: String) {
        guard let window = view.window, window.isVisible else {
            Self.logger.notice("Settings error not shown, the window is closed: \(title, privacy: .public)")
            return
        }
        AlertHelper.showErrorSheet(title: title, message: message, window: window)
    }
}
