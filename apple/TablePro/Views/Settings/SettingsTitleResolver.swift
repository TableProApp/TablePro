import Combine
import Foundation

// Answers the navigation model's two questions about routes whose subject lives outside Settings:
// does it still exist, and what is it called. It also feeds those names to the sidebar search.
@MainActor
internal final class SettingsTitleResolver {
    internal struct Sources {
        internal var plugins: @MainActor () -> [PluginEntry]
        internal var rejectedPlugins: @MainActor () -> [RejectedPlugin]
        internal var providers: @MainActor () -> [AIProviderConfig]
        internal var isSignedIn: @MainActor () -> Bool
        internal var isAIEnabled: @MainActor () -> Bool
        internal var isMCPEnabled: @MainActor () -> Bool
        internal var changes: @MainActor () -> [AnyPublisher<Void, Never>]

        internal static var live: Sources {
            Sources(
                plugins: { PluginManager.shared.plugins },
                rejectedPlugins: { PluginManager.shared.rejectedPlugins },
                providers: { AppSettingsManager.shared.ai.providers },
                isSignedIn: { FeatureAccess.shared.state.isSignedIn },
                isAIEnabled: { AppSettingsManager.shared.ai.enabled },
                isMCPEnabled: { AppSettingsManager.shared.mcp.enabled },
                changes: {
                    [
                        PluginManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                        AppSettingsManager.shared.aiSlice.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                        AppSettingsManager.shared.mcpSlice.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                        FeatureAccess.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                    ]
                }
            )
        }
    }

    private let sources: Sources
    private var subscription: AnyCancellable?

    internal init(sources: Sources = .live) {
        self.sources = sources
    }

    // A page the pane root hides is unavailable, so Back, Forward and links never land on it.
    internal func isAvailable(_ route: SettingsRoute) -> Bool {
        switch route {
        case .page(.accountDevices), .page(.accountTeams):
            sources.isSignedIn()
        case .page(.slashCommands):
            sources.isAIEnabled()
        case .page(.mcpApprovals), .page(.mcpTokens):
            sources.isMCPEnabled()
        case .page:
            true
        case .plugin(let id):
            sources.plugins().contains { $0.id == id }
        case .rejectedPlugin(let url):
            sources.rejectedPlugins().contains { $0.url == url }
        case .aiProvider(let id):
            sources.isAIEnabled() && sources.providers().contains { $0.id == id }
        }
    }

    internal func title(for route: SettingsRoute) -> String? {
        switch route {
        case .page:
            nil
        case .plugin(let id):
            sources.plugins().first { $0.id == id }?.name
        case .rejectedPlugin(let url):
            sources.rejectedPlugins().first { $0.url == url }?.name
        case .aiProvider(let id):
            sources.providers().first { $0.id == id }?.displayName
        }
    }

    internal var searchEntries: [SettingsSearchEntry] {
        let plugins = sources.plugins().map {
            SettingsSearchEntry(title: $0.name, location: SettingsLocation(route: .plugin(id: $0.id)))
        }
        guard sources.isAIEnabled() else { return plugins }
        let providers = sources.providers().map {
            SettingsSearchEntry(title: $0.displayName, location: SettingsLocation(route: .aiProvider($0.id)))
        }
        return plugins + providers
    }

    // Delivered a run-loop turn later: objectWillChange fires before the new value lands.
    internal func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        subscription = Publishers.MergeMany(sources.changes())
            .receive(on: RunLoop.main)
            .sink { _ in
                MainActor.assumeIsolated { onChange() }
            }
    }

    internal func stopObserving() {
        subscription = nil
    }
}
