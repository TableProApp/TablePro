import Combine
import Foundation

// Counts shows of a pane and key-window returns while it is shown, so a pane reloads with .task(id: visit.count).
@MainActor
internal final class SettingsPaneVisit: ObservableObject {
    @Published internal private(set) var count = 0

    internal func bump() {
        count += 1
    }
}

// The toolbar search field of a pane that filters its own list (Keyboard, Extensions).
@MainActor
internal final class SettingsPaneFilter: ObservableObject {
    @Published internal var query = ""
}

// Live for the window controller's lifetime, so a pane switch or a close never drops their state.
@MainActor
internal final class SettingsWindowModels {
    internal private(set) lazy var themeLibrary = ThemeLibraryModel(
        catalog: .shared,
        selection: AppSettingsManager.shared,
        editors: ThemeEditorWindows.shared
    )

    internal private(set) lazy var account = AccountSettingsModel(services: .shared)
}

// A class, so a pane entry holding it compares equal across renders and keeps its body.
@MainActor
internal final class SettingsPaneContext {
    internal let pane: SettingsPane
    internal let settings: AppSettingsManager
    internal let navigation: SettingsNavigationModel
    internal let models: SettingsWindowModels
    internal let registryClient: RegistryClient
    internal let visit = SettingsPaneVisit()
    internal let filter: SettingsPaneFilter?
    private let errorPresenter: (_ title: String, _ message: String) -> Void

    internal init(
        pane: SettingsPane,
        settings: AppSettingsManager,
        navigation: SettingsNavigationModel,
        models: SettingsWindowModels,
        registryClient: RegistryClient,
        presentError: @escaping (_ title: String, _ message: String) -> Void
    ) {
        self.pane = pane
        self.settings = settings
        self.navigation = navigation
        self.models = models
        self.registryClient = registryClient
        self.filter = Self.filtersItsList(pane) ? SettingsPaneFilter() : nil
        self.errorPresenter = presentError
    }

    internal var path: SettingsPanePath {
        navigation.path(for: pane)
    }

    internal var isCurrent: Bool {
        navigation.location.pane == pane
    }

    // For errors raised while the page that caused them is not on screen.
    internal func presentError(title: String, message: String) {
        errorPresenter(title, message)
    }

    internal static func filtersItsList(_ pane: SettingsPane) -> Bool {
        pane == .keyboard || pane == .plugins
    }
}
