import Foundation

@MainActor
internal struct MCPServerComposition {
    internal let tokenStore: MCPTokenStore
    internal let rateLimiter: MCPRateLimiter
    internal let authenticator: MCPCompositeAuthenticator
    internal let services: MCPToolServices
    internal let activityLedger: MCPClientActivityLedger
    internal let subscriptions: MCPSubscriptionRegistry
    internal let subscriptionEvents: MCPSubscriptionEventSource
    internal let legacyAdapter: MCPLegacyEraAdapter
    internal let dispatcher: MCPProtocolDispatcher
    internal let transport: MCPHttpServerTransport

    internal var authPolicy: MCPAuthPolicy {
        services.authPolicy
    }

    internal static func build(
        port: UInt16,
        settings: MCPSettings,
        tokenStore: MCPTokenStore
    ) -> MCPServerComposition {
        let rateLimiter = MCPRateLimiter()
        let authenticator = MCPCompositeAuthenticator(
            bearer: MCPBearerTokenAuthenticator(tokenStore: tokenStore, rateLimiter: rateLimiter),
            requireAuthentication: settings.requireAuthentication
        )
        let transport = MCPHttpServerTransport(
            configuration: .loopback(port: port),
            authenticator: authenticator
        )
        let subscriptions = MCPSubscriptionRegistry()
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        let activityLedger = MCPClientActivityLedger()
        let legacyAdapter = MCPLegacyEraAdapter()
        let dispatcher = MCPProtocolDispatcher(
            handlers: MCPMethodRegistry.handlers(services: services, subscriptions: subscriptions),
            legacyAdapter: legacyAdapter,
            activityLedger: activityLedger,
            serverInfo: MCPMethodRegistry.serverInfo,
            rateLimiter: rateLimiter
        )

        return MCPServerComposition(
            tokenStore: tokenStore,
            rateLimiter: rateLimiter,
            authenticator: authenticator,
            services: services,
            activityLedger: activityLedger,
            subscriptions: subscriptions,
            subscriptionEvents: MCPSubscriptionEventSource(registry: subscriptions),
            legacyAdapter: legacyAdapter,
            dispatcher: dispatcher,
            transport: transport
        )
    }

    internal func start() async {
        subscriptionEvents.start()
        await legacyAdapter.startIdleSweep()
    }

    internal func teardown() async {
        subscriptionEvents.stop()
        await legacyAdapter.shutdown()
        await subscriptions.closeAll()
        await dispatcher.cancelAllInflight()
        await transport.stop()
        await services.authPolicy.clearAllApprovals()
    }
}
