import Foundation

public enum MCPMethodRegistry {
    public static let serverInfo = MCPImplementation(
        name: "tablepro",
        title: "TablePro",
        version: appVersion,
        websiteUrl: "https://tablepro.app"
    )

    public static let instructions = String(localized: """
    TablePro is a native macOS database client. This server exposes the connections the user has already \
    configured, so you never handle credentials: name a connection by its id and TablePro opens, reuses and \
    authorizes it for you.

    Start with list_connections, then list_databases, list_schemas and list_tables to find your way around, and \
    describe_table before writing any query, because it returns the columns, indexes and foreign keys you need \
    to get the SQL right the first time. Prefer the dedicated tools over hand-written SQL wherever one exists: \
    they quote identifiers correctly for the engine in front of you, apply the user's row limits, and are \
    allowed on connections where raw execution is not.

    Every connection carries the user's own policy. A connection may be read-only for external clients, may be \
    invisible to AI entirely, and may be in a safe mode that asks the user to confirm each write. A refusal is \
    that policy speaking, not a transient error, so do not retry it and do not look for a way around it. \
    Destructive statements need the user's consent, which TablePro collects itself.
    """)

    public static func capabilities(
        supportsPrompts: Bool = true,
        supportsCompletions: Bool = true
    ) -> MCPServerCapabilities {
        MCPServerCapabilities(
            tools: MCPServerCapabilities.ListChanged(listChanged: false),
            resources: MCPServerCapabilities.Resources(subscribe: true, listChanged: true),
            prompts: supportsPrompts ? MCPServerCapabilities.ListChanged(listChanged: false) : nil,
            completions: supportsCompletions,
            extensions: [:]
        )
    }

    public static func handlers(
        services: MCPToolServices,
        subscriptions: MCPSubscriptionRegistry
    ) -> [any MCPMethodHandler] {
        [
            DiscoverHandler(),
            ToolsListHandler(),
            ToolsCallHandler(services: services),
            ResourcesListHandler(services: services),
            ResourcesReadHandler(services: services),
            ResourcesTemplatesListHandler(),
            PromptsListHandler(),
            PromptsGetHandler(services: services),
            CompletionCompleteHandler(services: services),
            SubscriptionsListenHandler(subscriptions: subscriptions),
            InitializeHandler(),
            PingHandler(),
            LegacyLoggingSetLevelHandler()
        ]
    }

    private static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
}
