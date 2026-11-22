import Foundation
@testable import TablePro
import Testing

@MainActor
struct SettingsNavigationModelTests {
    @MainActor
    private final class Recorder {
        var locations: [SettingsLocation] = []
        var picks: [SettingsPane] = []
        var unavailable: Set<SettingsRoute> = []

        func attach(to model: SettingsNavigationModel) {
            model.onLocationChange = { [unowned self] in locations.append($0) }
            model.onUserPick = { [unowned self] in picks.append($0) }
            model.isRouteAvailable = { [unowned self] in !unavailable.contains($0) }
        }
    }

    private let themes = SettingsLocation(page: .manageThemes)
    private let sqlFormatting = SettingsLocation(page: .sqlFormatting)
    private let driver = SettingsRoute.plugin(id: "com.example.driver")

    @Test("A sidebar pick is a history entry that Back leaves and Forward returns to")
    func paneSwitchRecordsHistory() {
        let model = SettingsNavigationModel(initial: .root(.general))
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)

        model.select(.editor)
        #expect(model.location == .root(.editor))
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        model.goBack()
        #expect(model.location == .root(.general))
        #expect(!model.canGoBack)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.location == .root(.editor))
        #expect(model.canGoBack)
        #expect(!model.canGoForward)
    }

    @Test("Picking the current pane at its root changes nothing")
    func reselectingTheRootChangesNothing() {
        let model = SettingsNavigationModel(initial: .root(.general))
        let recorder = Recorder()
        recorder.attach(to: model)

        model.select(.general)
        #expect(recorder.locations.isEmpty)
        #expect(!model.canGoBack)
    }

    @Test("Picking the current pane while on one of its pages pops to the root as a new entry")
    func reselectingWhileDrilledPopsToRoot() {
        let model = SettingsNavigationModel(initial: .root(.appearance))
        #expect(model.push(.page(.manageThemes), in: .appearance))
        #expect(model.location == themes)

        model.select(.appearance)
        #expect(model.location == .root(.appearance))
        #expect(model.canGoBack)

        model.goBack()
        #expect(model.location == themes)
    }

    @Test("A push is a history entry and the title follows the top route")
    func pushRecordsHistoryAndTitles() {
        let model = SettingsNavigationModel(initial: .root(.appearance))
        #expect(model.title == SettingsPane.appearance.title)

        model.push(.page(.manageThemes), in: .appearance)
        #expect(model.title == SettingsPage.manageThemes.title)
        #expect(model.canGoBack)

        model.goBack()
        #expect(model.title == SettingsPane.appearance.title)
        #expect(model.canGoForward)
    }

    @Test("A push from another pane, of another pane's route or of the route already on top does nothing")
    func pushIsGuardedByTheCurrentPane() {
        let model = SettingsNavigationModel(initial: .root(.appearance))
        let recorder = Recorder()
        recorder.attach(to: model)

        #expect(!model.push(.page(.sqlFormatting), in: .editor))
        #expect(!model.push(.page(.sqlFormatting), in: .appearance))
        #expect(recorder.locations.isEmpty)

        #expect(model.push(.page(.manageThemes), in: .appearance))
        #expect(!model.push(.page(.manageThemes), in: .appearance))
        #expect(model.location == themes)
        #expect(recorder.locations == [themes])
    }

    @Test("A new entry after Back drops the forward history")
    func newEntryTruncatesForwardHistory() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.editor)
        model.select(.data)
        model.goBack()
        model.goBack()
        #expect(model.location == .root(.general))
        #expect(model.canGoForward)

        model.select(.ai)
        #expect(!model.canGoForward)

        model.goBack()
        #expect(model.location == .root(.general))
        model.goForward()
        #expect(model.location == .root(.ai))
    }

    @Test("A stack that grows records an entry, and a pop to the previous entry is a Back")
    func stackBindingGrowsAndPops() {
        let model = SettingsNavigationModel(initial: .root(.editor))

        model.setRoutes([.page(.sqlFormatting)], for: .editor)
        #expect(model.location == sqlFormatting)
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        model.setRoutes([], for: .editor)
        #expect(model.location == .root(.editor))
        #expect(!model.canGoBack)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.location == sqlFormatting)
    }

    @Test("A pop that does not match the previous entry records a new entry")
    func stackPopToAnOlderLocationRecordsAnEntry() {
        let other = SettingsRoute.plugin(id: "com.example.other")
        let model = SettingsNavigationModel(initial: .root(.plugins))
        model.push(driver, in: .plugins)
        model.push(other, in: .plugins)

        model.setRoutes([], for: .plugins)
        #expect(model.location == .root(.plugins))
        #expect(!model.canGoForward)

        model.goBack()
        #expect(model.location == SettingsLocation(pane: .plugins, routes: [driver, other]))
    }

    @Test("A stack binding of a pane that is no longer current is ignored")
    func stackBindingOfAnotherPaneIsIgnored() {
        let model = SettingsNavigationModel(initial: .root(.editor))
        let recorder = Recorder()
        recorder.attach(to: model)

        model.setRoutes([.page(.manageThemes)], for: .appearance)
        model.setRoutes([], for: .editor)
        #expect(model.location == .root(.editor))
        #expect(recorder.locations.isEmpty)
    }

    @Test("Back and Forward skip unavailable entries and keep them in order")
    func unavailableEntriesAreSkipped() {
        let model = SettingsNavigationModel(initial: .root(.general))
        let recorder = Recorder()
        recorder.attach(to: model)
        model.select(.plugins)
        model.push(driver, in: .plugins)
        model.select(.editor)

        recorder.unavailable = [driver]
        model.goBack()
        #expect(model.location == .root(.plugins))

        model.goForward()
        #expect(model.location == .root(.editor))

        recorder.unavailable = []
        model.goBack()
        #expect(model.location == SettingsLocation(route: driver))
        model.goBack()
        #expect(model.location == .root(.plugins))
    }

    @Test("Back is disabled when every earlier entry is unavailable")
    func backIsDisabledWhenNothingEarlierIsAvailable() {
        let model = SettingsNavigationModel(initial: SettingsLocation(route: driver))
        let recorder = Recorder()
        recorder.attach(to: model)
        model.select(.editor)
        #expect(model.canGoBack)

        recorder.unavailable = [driver]
        #expect(!model.canGoBack)
        model.goBack()
        #expect(model.location == .root(.editor))
    }

    @Test("Forward is disabled when every later entry is unavailable")
    func forwardIsDisabledWhenNothingLaterIsAvailable() {
        let model = SettingsNavigationModel(initial: .root(.plugins))
        let recorder = Recorder()
        recorder.attach(to: model)
        model.push(driver, in: .plugins)
        model.setRoutes([], for: .plugins)
        #expect(model.canGoForward)

        recorder.unavailable = [driver]
        #expect(!model.canGoForward)
        model.goForward()
        #expect(model.location == .root(.plugins))
    }

    @Test("A deep link into a closed window opens the page with Back to its pane root")
    func closedWindowDeepLinkSeedsThePaneRoot() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.editor)
        model.select(.data)

        model.open(themes, recordsHistory: false)
        #expect(model.location == themes)
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        model.goBack()
        #expect(model.location == .root(.appearance))
        #expect(!model.canGoBack)
    }

    @Test("Opening a pane root into a closed window starts with no history")
    func closedWindowOpenOfARootHasNoHistory() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.editor)

        model.open(.root(.ai), recordsHistory: false)
        #expect(model.location == .root(.ai))
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
    }

    @Test("A deep link into an open window records an entry and Back passes the page's pane root")
    func openWindowDeepLinkRecordsHistory() {
        let model = SettingsNavigationModel(initial: .root(.general))

        model.open(sqlFormatting, recordsHistory: true)
        #expect(model.location == sqlFormatting)

        model.goBack()
        #expect(model.location == .root(.editor))
        model.goBack()
        #expect(model.location == .root(.general))
        #expect(!model.canGoBack)
    }

    @Test("A deep link from the page's own pane root adds one entry")
    func openWindowDeepLinkFromTheSameRoot() {
        let model = SettingsNavigationModel(initial: .root(.editor))

        model.open(sqlFormatting, recordsHistory: true)
        model.goBack()
        #expect(model.location == .root(.editor))
        #expect(!model.canGoBack)
    }

    @Test("A deep link to the location already shown changes nothing")
    func openWindowDeepLinkToTheCurrentLocation() {
        let model = SettingsNavigationModel(initial: sqlFormatting)
        let recorder = Recorder()
        recorder.attach(to: model)

        model.open(sqlFormatting, recordsHistory: true)
        #expect(recorder.locations.isEmpty)
        #expect(!model.canGoBack)
    }

    @Test("An open stops at the first unavailable route, and an unloaded plugin becomes a pending reveal")
    func openTruncatesAtAnUnavailableRoute() {
        let model = SettingsNavigationModel(initial: .root(.general))
        let recorder = Recorder()
        recorder.attach(to: model)
        recorder.unavailable = [driver, .page(.accountTeams)]

        model.open(SettingsLocation(route: driver), recordsHistory: false)
        #expect(model.location == .root(.plugins))
        #expect(!model.canGoBack)
        #expect(model.pendingPluginReveal?.pluginId == "com.example.driver")

        model.open(SettingsLocation(page: .accountTeams), recordsHistory: true)
        #expect(model.location == .root(.account))
    }

    @Test("Only a sidebar pick reports a pane to persist")
    func onlyAUserPickPersists() {
        let model = SettingsNavigationModel(initial: .root(.general))
        let recorder = Recorder()
        recorder.attach(to: model)

        model.open(.root(.ai), recordsHistory: true)
        model.open(themes, recordsHistory: false)
        model.push(.page(.manageThemes), in: .appearance)
        model.setRoutes([], for: .appearance)
        model.goBack()
        model.goForward()
        model.removeRoute(.page(.manageThemes))
        model.resetHistory()
        #expect(recorder.picks.isEmpty)

        model.select(.mcp)
        #expect(recorder.picks == [.mcp])
    }

    @Test("Removing a route pops the page shown and drops it from history")
    func removeRoutePopsAndPurges() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.plugins)
        model.push(driver, in: .plugins)

        model.removeRoute(driver)
        #expect(model.location == .root(.plugins))
        #expect(!model.canGoForward)
        model.goBack()
        #expect(model.location == .root(.general))
        #expect(!model.canGoBack)
    }

    @Test("Removing a route that is not shown leaves the location and drops it from both stacks")
    func removeRouteFromHistoryOnly() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.plugins)
        model.push(driver, in: .plugins)
        model.select(.editor)
        model.select(.data)
        model.goBack()

        model.removeRoute(driver)
        #expect(model.location == .root(.editor))
        model.goBack()
        #expect(model.location == .root(.plugins))
        model.goBack()
        #expect(model.location == .root(.general))
        model.goForward()
        model.goForward()
        model.goForward()
        #expect(model.location == .root(.data))
    }

    @Test("Removing a route that appears nowhere does nothing")
    func removeRouteThatIsAbsent() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.editor)
        let recorder = Recorder()
        recorder.attach(to: model)

        model.removeRoute(driver)
        #expect(recorder.locations.isEmpty)
        #expect(model.canGoBack)
    }

    @Test("Resetting history keeps the location")
    func resetHistoryKeepsTheLocation() {
        let model = SettingsNavigationModel(initial: .root(.general))
        model.select(.editor)
        model.select(.data)
        model.goBack()

        model.resetHistory()
        #expect(model.location == .root(.editor))
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
    }

    @Test("Each pane path holds the routes only while its pane is current")
    func panePathsFollowTheLocation() {
        let model = SettingsNavigationModel(initial: .root(.appearance))
        let appearance = model.path(for: .appearance)
        let editor = model.path(for: .editor)
        #expect(model.path(for: .appearance) === appearance)

        model.push(.page(.manageThemes), in: .appearance)
        #expect(appearance.routes == [.page(.manageThemes)])
        #expect(editor.routes.isEmpty)

        model.select(.editor)
        #expect(appearance.routes.isEmpty)

        model.goBack()
        #expect(appearance.routes == [.page(.manageThemes)])
        #expect(model.path(for: .data).routes.isEmpty)
    }

    @Test("onLocationChange runs once per change")
    func locationChangeIsReportedOnce() {
        let model = SettingsNavigationModel(initial: .root(.general))
        let recorder = Recorder()
        recorder.attach(to: model)

        model.select(.editor)
        model.push(.page(.sqlFormatting), in: .editor)
        model.goBack()
        #expect(recorder.locations == [.root(.editor), sqlFormatting, .root(.editor)])
    }

    @Test("Dynamic titles come from the resolver, with a fallback per route")
    func titlesComeFromTheResolver() {
        let provider = UUID()
        let model = SettingsNavigationModel(
            initial: .root(.plugins),
            titleResolver: { route in route == .plugin(id: "com.example.driver") ? "Example Driver" : nil }
        )

        model.push(driver, in: .plugins)
        #expect(model.title == "Example Driver")

        let rejected = URL(fileURLWithPath: "/tmp/Old Driver.tableplugin")
        #expect(model.title(for: .rejectedPlugin(rejected)) == "Old Driver")
        #expect(model.title(for: .plugin(id: "com.example.other")) == SettingsRoute.plugin(id: "x").defaultTitle)
        #expect(model.title(for: .aiProvider(provider)) == SettingsRoute.aiProvider(provider).defaultTitle)
        #expect(model.title(for: .page(.accountOffline)) == SettingsPage.accountOffline.title)
    }

    @Test("A plugin reveal is consumed once, and each request is distinct")
    func pluginRevealIsConsumedOnce() {
        let model = SettingsNavigationModel()
        #expect(model.pendingPluginReveal == nil)

        model.requestPluginReveal(nil)
        let first = model.pendingPluginReveal
        model.requestPluginReveal(nil)
        let second = model.pendingPluginReveal
        #expect(first != nil)
        #expect(first != second)
        #expect(second?.pluginId == nil)

        #expect(model.consumePluginReveal() == second)
        #expect(model.consumePluginReveal() == nil)
        #expect(model.pluginReveal.pending == nil)
    }

    @Test("A location keeps only the routes of its own pane")
    func locationDropsForeignRoutes() {
        let location = SettingsLocation(pane: .editor, routes: [.page(.sqlFormatting), .page(.manageThemes), .page(.sqlFormatting)])
        #expect(location.routes == [.page(.sqlFormatting)])
        #expect(SettingsLocation(pane: .ai, routes: [.page(.manageThemes)]).isRoot)
        #expect(SettingsLocation(route: .aiProvider(UUID())).pane == .ai)
        #expect(SettingsLocation(route: .rejectedPlugin(URL(fileURLWithPath: "/tmp/x.tableplugin"))).pane == .plugins)
    }
}
