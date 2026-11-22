import Combine
import SwiftUI
import TableProMCP

// One per Settings window, shared by the pane root and its pages, so a push or a pane switch keeps the rows.
@MainActor
final class MCPSettingsModel: ObservableObject {
    @Published private(set) var tokenStore: MCPTokenStore?
    @Published private(set) var tokens: [MCPAuthToken] = []
    @Published private(set) var hasLoadedTokens = false
    @Published private(set) var grants: [MCPConnectionGrant] = []
    @Published private(set) var hasLoadedGrants = false
    @Published private(set) var connectionNames: [UUID: String] = [:]
    @Published private(set) var tokenNames: [UUID: String] = [:]

    private let manager: MCPServerManager
    private var storeSubscription: AnyCancellable?
    private var tokenTask: Task<Void, Never>?
    private var grantTask: Task<Void, Never>?
    private var tokenGeneration = 0
    private var grantGeneration = 0

    init(manager: MCPServerManager) {
        self.manager = manager
    }

    convenience init() {
        self.init(manager: .shared)
    }

    deinit {
        tokenTask?.cancel()
        grantTask?.cancel()
    }

    var activeTokenCount: Int {
        tokens.filter { $0.isEffectivelyActive }.count
    }

    func activate() {
        guard storeSubscription == nil else { return }
        let grantChanges = manager.grantChanges.changes()
        grantTask = Task { [weak self] in
            for await _ in grantChanges {
                await self?.reloadGrants()
            }
        }
        storeSubscription = manager.$tokenStore
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] store in self?.adopt(store) }
    }

    func refresh() async {
        await reloadTokens()
        await reloadGrants()
    }

    func reloadTokens() async {
        tokenGeneration += 1
        let generation = tokenGeneration
        guard let store = tokenStore else { return }
        let listed = await store.list()
        guard generation == tokenGeneration, store === tokenStore else { return }
        tokens = listed.filter(\.isUserManaged)
        hasLoadedTokens = true
    }

    func reloadGrants() async {
        grantGeneration += 1
        let generation = grantGeneration
        let loaded = await manager.connectionGrants()
        let named = await tokenStore?.list() ?? []
        guard generation == grantGeneration else { return }
        grants = loaded.sorted { $0.grantedAt > $1.grantedAt }
        tokenNames = Dictionary(named.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        connectionNames = Dictionary(
            ConnectionStorage.shared.loadConnections().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        hasLoadedGrants = true
    }

    func forgetGrant(_ grant: MCPConnectionGrant) async {
        await manager.forgetGrant(subject: grant.subject, connectionId: grant.connectionId)
        await reloadGrants()
    }

    func forgetEveryGrant() async {
        await manager.forgetEveryGrant()
        await reloadGrants()
    }

    func generate(_ request: MCPTokenRequest, configuredPort: Int) async -> Result<MCPTokenReveal, MCPTokenCreateFailure> {
        guard let store = tokenStore else {
            return .failure(MCPTokenCreateFailure(
                message: String(localized: "The MCP server is not running, so TablePro cannot save a token now. Start the server, then try again."),
                endsSheet: true
            ))
        }
        let access: ConnectionAccess = request.connectionIds.map { .limited($0) } ?? .all
        do {
            let result = try await store.generate(
                name: request.name,
                permissions: request.permissions,
                connectionAccess: access,
                expiresAt: request.expiresAt,
                isBridgeCredential: false,
                isClaudeAgentCredential: false,
                extraScopes: []
            )
            await reloadTokens()
            let port = manager.listeningPort ?? configuredPort
            return .success(MCPTokenReveal(
                plaintext: result.plaintext,
                setup: MCPHTTPClientSetup(port: port),
                port: port,
                configuredPort: configuredPort
            ))
        } catch {
            return .failure(MCPTokenCreateFailure(message: Self.generateFailureMessage(error), endsSheet: false))
        }
    }

    func revoke(_ ids: Set<UUID>) async -> MCPTokenAlert? {
        guard tokenStore != nil else { return .serverNotRunning }
        var allSaved = true
        for id in ids {
            let saved = await manager.revokeToken(id: id)
            allSaved = allSaved && saved
        }
        await reloadTokens()
        return allSaved ? nil : .revocationNotSaved
    }

    func delete(_ ids: Set<UUID>) async -> MCPTokenAlert? {
        guard let store = tokenStore else { return .serverNotRunning }
        var allSaved = true
        for id in ids {
            let saved = await store.delete(tokenId: id)
            allSaved = allSaved && saved
        }
        await reloadTokens()
        return allSaved ? nil : .deletionNotSaved
    }

    private func adopt(_ store: MCPTokenStore?) {
        tokenStore = store
        tokenTask?.cancel()
        tokenTask = nil
        guard let store else { return }
        let changes = store.membershipChanges.changes()
        tokenTask = Task { [weak self] in
            await self?.reloadTokens()
            await self?.reloadGrants()
            for await _ in changes {
                await self?.reloadTokens()
                await self?.reloadGrants()
            }
        }
    }

    private static func generateFailureMessage(_ error: Error) -> String {
        switch error as? MCPTokenStoreError {
        case .storedTokensUnreadable?:
            String(localized: "TablePro could not read the tokens saved in the Keychain, so it will not save a new one over them. Restart TablePro and try again.")
        case .randomGenerationFailed?:
            String(localized: "macOS could not generate a secure token. Try again.")
        case .keychainUnavailable?, .notSaved?, nil:
            String(localized: "TablePro could not save the token to the Keychain, so it was not created. Try again.")
        }
    }
}

struct MCPSettingsView: View {
    @Binding var settings: MCPSettings
    @ObservedObject var model: MCPSettingsModel
    let onChangeAIPolicy: () -> Void

    var body: some View {
        Form {
            MCPSection(settings: $settings, model: model, onChangeAIPolicy: onChangeAIPolicy)
            MCPOutsideServersSection()
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-mcp")
    }
}
