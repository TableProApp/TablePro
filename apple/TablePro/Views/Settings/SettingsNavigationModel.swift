import Combine
import Foundation

// Each pane host observes only its own path, so a push in one pane never re-renders another.
@MainActor
final class SettingsPanePath: ObservableObject {
    let pane: SettingsPane
    @Published fileprivate(set) var routes: [SettingsRoute]

    fileprivate init(pane: SettingsPane, routes: [SettingsRoute]) {
        self.pane = pane
        self.routes = routes
    }
}

@MainActor
final class SettingsPluginReveal: ObservableObject {
    struct Request: Equatable, Sendable {
        let id: UUID
        let pluginId: String?
    }

    @Published private(set) var pending: Request?

    fileprivate init() {}

    // A nil id asks for the first plugin that needs an update (PluginListSelection.revealTarget).
    func request(pluginId: String?) {
        pending = Request(id: UUID(), pluginId: pluginId)
    }

    func consume() -> Request? {
        let request = pending
        pending = nil
        return request
    }
}

// Every mutation goes through apply, which syncs the pane paths and then calls onLocationChange once.
@MainActor
final class SettingsNavigationModel {
    private(set) var location: SettingsLocation
    private var backStack: [SettingsLocation] = []
    private var forwardStack: [SettingsLocation] = []
    private var panePaths: [SettingsPane: SettingsPanePath] = [:]

    let pluginReveal = SettingsPluginReveal()

    var isRouteAvailable: (SettingsRoute) -> Bool
    var titleResolver: (SettingsRoute) -> String?
    var onLocationChange: ((SettingsLocation) -> Void)?
    var onUserPick: ((SettingsPane) -> Void)?

    init(
        initial: SettingsLocation = .root(SettingsNavigation.defaultPane),
        isRouteAvailable: @escaping (SettingsRoute) -> Bool = { _ in true },
        titleResolver: @escaping (SettingsRoute) -> String? = { _ in nil }
    ) {
        self.location = initial
        self.isRouteAvailable = isRouteAvailable
        self.titleResolver = titleResolver
    }

    var canGoBack: Bool { backStack.contains { isAvailable($0) } }
    var canGoForward: Bool { forwardStack.contains { isAvailable($0) } }

    var title: String { title(for: location) }

    func title(for location: SettingsLocation) -> String {
        guard let route = location.routes.last else { return location.pane.title }
        return title(for: route)
    }

    func title(for route: SettingsRoute) -> String {
        titleResolver(route) ?? route.defaultTitle
    }

    func isAvailable(_ location: SettingsLocation) -> Bool {
        location.routes.allSatisfy { isRouteAvailable($0) }
    }

    func path(for pane: SettingsPane) -> SettingsPanePath {
        if let path = panePaths[pane] { return path }
        let path = SettingsPanePath(pane: pane, routes: pane == location.pane ? location.routes : [])
        panePaths[pane] = path
        return path
    }

    // Only a user's sidebar pick persists the pane.
    func select(_ pane: SettingsPane) {
        onUserPick?(pane)
        let target = SettingsLocation.root(pane)
        guard target != location else { return }
        record(target)
    }

    // The NavigationStack path binding: a pop to the previous entry counts as Back.
    func setRoutes(_ routes: [SettingsRoute], for pane: SettingsPane) {
        guard pane == location.pane else { return }
        let target = SettingsLocation(pane: pane, routes: routes)
        guard target != location else { return }
        if target.routes.count < location.routes.count, backStack.last == target {
            apply(target, back: Array(backStack.dropLast()), forward: forwardStack + [location])
        } else {
            record(target)
        }
    }

    // For async completions: a no-op unless the pane is still current and the route is not already on top.
    @discardableResult
    func push(_ route: SettingsRoute, in pane: SettingsPane) -> Bool {
        guard pane == location.pane, route.pane == pane, location.routes.last != route else { return false }
        record(SettingsLocation(pane: pane, routes: location.routes + [route]))
        return true
    }

    // The route's subject is gone, so no history entry may lead back to it.
    func removeRoute(_ route: SettingsRoute) {
        var current = location
        if let index = location.routes.firstIndex(of: route) {
            current = SettingsLocation(pane: location.pane, routes: Array(location.routes[..<index]))
        }
        let back = Self.collapsed(backStack.filter { !$0.routes.contains(route) }, before: current)
        let forward = Self.collapsed(forwardStack.filter { !$0.routes.contains(route) }, before: current)
        apply(current, back: back, forward: forward)
    }

    // Never persists. A page gets its pane root before it in history, so Back returns there.
    func open(_ requested: SettingsLocation, recordsHistory: Bool) {
        let target = availablePrefix(of: requested)
        let root = target.root
        guard recordsHistory else {
            apply(target, back: target.isRoot ? [] : [root], forward: [])
            return
        }
        guard target != location else { return }
        var back = backStack
        back.append(location)
        if !target.isRoot, location != root {
            back.append(root)
        }
        apply(target, back: Self.collapsed(back, before: target), forward: [])
    }

    // Unavailable entries are passed over but kept, in order, on the other stack.
    func goBack() {
        guard let index = backStack.lastIndex(where: { isAvailable($0) }) else { return }
        let skipped: [SettingsLocation] = backStack[(index + 1)...].reversed()
        apply(backStack[index], back: Array(backStack[..<index]), forward: forwardStack + [location] + skipped)
    }

    func goForward() {
        guard let index = forwardStack.lastIndex(where: { isAvailable($0) }) else { return }
        let skipped: [SettingsLocation] = forwardStack[(index + 1)...].reversed()
        apply(forwardStack[index], back: backStack + [location] + skipped, forward: Array(forwardStack[..<index]))
    }

    func resetHistory() {
        apply(location, back: [], forward: [])
    }

    // Availability or a title source changed outside the model, so the shell re-reads both.
    func refresh() {
        onLocationChange?(location)
    }

    var pendingPluginReveal: SettingsPluginReveal.Request? { pluginReveal.pending }

    func requestPluginReveal(_ pluginId: String?) {
        pluginReveal.request(pluginId: pluginId)
    }

    func consumePluginReveal() -> SettingsPluginReveal.Request? {
        pluginReveal.consume()
    }

    private func record(_ target: SettingsLocation) {
        apply(target, back: backStack + [location], forward: [])
    }

    // An unloaded plugin becomes a pending reveal the Extensions pane resolves after its list loads.
    private func availablePrefix(of requested: SettingsLocation) -> SettingsLocation {
        guard let index = requested.routes.firstIndex(where: { !isRouteAvailable($0) }) else { return requested }
        if case .plugin(let id) = requested.routes[index] {
            requestPluginReveal(id)
        }
        return SettingsLocation(pane: requested.pane, routes: Array(requested.routes[..<index]))
    }

    private func apply(_ target: SettingsLocation, back: [SettingsLocation], forward: [SettingsLocation]) {
        guard target != location || back != backStack || forward != forwardStack else { return }
        location = target
        backStack = back
        forwardStack = forward
        for (pane, path) in panePaths {
            let routes = pane == target.pane ? target.routes : []
            if path.routes != routes { path.routes = routes }
        }
        onLocationChange?(target)
    }

    // Drops repeats left behind by a removal, including an entry equal to the location it leads to.
    private static func collapsed(_ entries: [SettingsLocation], before next: SettingsLocation) -> [SettingsLocation] {
        var result: [SettingsLocation] = []
        for entry in entries where entry != result.last {
            result.append(entry)
        }
        while result.last == next {
            result.removeLast()
        }
        return result
    }
}
