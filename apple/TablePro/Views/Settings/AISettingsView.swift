import Combine
import SwiftUI

// Shared by the AI root and its provider pages for the window's life: key presence, account checks, the pending removal.
@MainActor
final class AISettingsPaneModel: ObservableObject {
    @Published var pendingRemoval: AIProviderConfig?
    @Published private(set) var providersWithKey: Set<UUID> = []

    private var accountChecks: [AIProviderType: Date] = [:]
    private let now: () -> Date

    static let accountCheckInterval: TimeInterval = 60

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func hasKey(_ providerID: UUID) -> Bool {
        providersWithKey.contains(providerID)
    }

    func setHasKey(_ hasKey: Bool, for providerID: UUID) {
        if hasKey {
            providersWithKey.insert(providerID)
        } else {
            providersWithKey.remove(providerID)
        }
    }

    // No Keychain read while AI is off.
    func refreshKeys(for settings: AISettings) async {
        guard settings.enabled else { return }
        let ids = settings.providers.filter { $0.authStyle.usesAPIKey }.map(\.id)
        let found = await AIProviderKeychain.providersWithKey(ids)
        if found != providersWithKey {
            providersWithKey = found
        }
    }

    // A check spawns the claude tool or reads the ChatGPT tokens, so a revisit within a minute reuses the last answer.
    func claimAccountChecks(_ types: Set<AIProviderType>) -> Set<AIProviderType> {
        let current = now()
        let due = types.filter { type in
            guard let last = accountChecks[type] else { return true }
            return current.timeIntervalSince(last) >= Self.accountCheckInterval
        }
        for type in due {
            accountChecks[type] = current
        }
        return due
    }

    func refreshAccounts(_ types: Set<AIProviderType>) async {
        let due = claimAccountChecks(types)
        guard !due.isEmpty else { return }
        let chatGPT = ChatGPTCodexService.shared
        let claudeAgent = ClaudeAgentService.shared
        await withTaskGroup(of: Void.self) { group in
            if due.contains(.chatgptCodex) {
                group.addTask { await chatGPT.refreshAuthState() }
            }
            if due.contains(.claudeAgent) {
                group.addTask { await claudeAgent.performRefresh() }
            }
        }
    }

    func remove(_ provider: AIProviderConfig, from slice: SettingsSlice<AISettings>, navigation: SettingsNavigationModel) {
        let id = provider.id
        AIKeyStorage.shared.deleteAPIKey(for: id)
        AIProviderFactory.invalidateCache(for: id)
        AIModelCatalog.shared.remove(providerID: id)
        slice.value = slice.value.removingProvider(id)
        providersWithKey.remove(id)
        navigation.removeRoute(.aiProvider(id))
    }
}

extension View {
    func aiProviderRemovalAlert(
        pending: Binding<AIProviderConfig?>,
        onConfirm: @escaping (AIProviderConfig) -> Void
    ) -> some View {
        alert(
            pending.wrappedValue.map { String(format: String(localized: "Remove “%@”?"), $0.displayName) } ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            presenting: pending.wrappedValue
        ) { provider in
            Button(String(localized: "Remove"), role: .destructive) {
                pending.wrappedValue = nil
                onConfirm(provider)
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pending.wrappedValue = nil
            }
        } message: { provider in
            Text(verbatim: provider.authStyle.usesAPIKey
                ? String(localized: "Its settings are removed from every Mac that syncs settings, and its API key is deleted from the Keychain.")
                : String(localized: "Its settings are removed from every Mac that syncs settings."))
        }
    }
}

struct AISettingsView: View {
    @Binding var settings: AISettings
    @ObservedObject var visit: SettingsPaneVisit

    @EnvironmentObject private var paneModel: AISettingsPaneModel
    @State private var addSession: AIProviderAddSession?
    @State private var appleIntelligence: AppleIntelligenceAvailability?

    var body: some View {
        Form {
            enableSection
            if settings.enabled {
                activeProviderSection
                providersSection
                if showsAppleIntelligence {
                    appleIntelligenceSection
                }
                inlineSuggestionsSection
                agentSection
                contextSection
                Section {
                    SlashCommandsDrillRow(storage: CustomSlashCommandStorage.shared)
                }
            }
            privacySection
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-ai")
        .task(id: visit.count) {
            appleIntelligence = SystemOnDeviceLanguageModel().availability
        }
        .task(id: KeyRefresh(visit: visit.count, enabled: settings.enabled, providerIDs: settings.providers.map(\.id))) {
            await paneModel.refreshKeys(for: settings)
        }
        .task(id: AccountRefresh(visit: visit.count, types: AIProviderAccountProbes.types(toProbe: settings))) {
            await paneModel.refreshAccounts(AIProviderAccountProbes.types(toProbe: settings))
        }
        .sheet(item: $addSession) { session in
            AIProviderAddSheet(session: session) { provider, hasKey in
                settings = settings.upserting(provider, makeActiveIfNone: true)
                paneModel.setHasKey(hasKey, for: provider.id)
            }
        }
    }

    private struct KeyRefresh: Equatable {
        let visit: Int
        let enabled: Bool
        let providerIDs: [UUID]
    }

    private struct AccountRefresh: Equatable {
        let visit: Int
        let types: Set<AIProviderType>
    }

    private var enableSection: some View {
        Section {
            Toggle(isOn: $settings.enabled) {
                Text("Enable AI features")
                Text("Chat, Agent mode, inline suggestions and query actions such as Explain and Optimize.")
            }
            .accessibilityIdentifier("settings-ai-enabled")
        }
    }

    private var activeProviderSection: some View {
        Section {
            Picker(selection: activeProviderBinding) {
                Text("None").tag(UUID?.none)
                ForEach(settings.providers) { provider in
                    Label {
                        Text(verbatim: provider.displayName)
                    } icon: {
                        provider.icon.menuImage()
                    }
                    .labelStyle(.titleAndIcon)
                    .tag(UUID?.some(provider.id))
                }
            } label: {
                Text("Active provider")
            }
            .pickerStyle(.menu)
            .disabled(settings.providers.isEmpty)
            .accessibilityIdentifier("settings-ai-active-provider")
        }
    }

    // An id whose provider another Mac removed reads as None, the provider that answers.
    private var activeProviderBinding: Binding<UUID?> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.activeProvider?.id },
            set: { settings.wrappedValue.activeProviderID = $0 }
        )
    }

    private var providersSection: some View {
        Section {
            if settings.providers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No providers")
                    Text("Add one to use chat and Agent mode.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ForEach(settings.providers) { provider in
                    providerLink(provider)
                }
            }
        } header: {
            Text("Providers")
        } footer: {
            SettingsSectionActions {
                AIProviderAddMenuButton { choice in
                    let registry = AIProviderRegistry.shared
                    addSession = AIProviderAddSession(
                        provider: choice.makeProvider { registry.descriptor(for: $0.rawValue) }
                    )
                }
            }
        }
    }

    private func providerLink(_ provider: AIProviderConfig) -> some View {
        let isActive = provider.id == settings.activeProvider?.id
        return NavigationLink(value: SettingsRoute.aiProvider(provider.id)) {
            AIProviderRow(provider: provider, isActive: isActive, hasKey: paneModel.hasKey(provider.id))
        }
        .contextMenu {
            Button(String(localized: "Set as Active")) {
                settings.activeProviderID = provider.id
            }
            .disabled(isActive)
            Divider()
            Button(String(localized: "Remove…"), role: .destructive) {
                paneModel.pendingRemoval = provider
            }
        }
        .accessibilityActions {
            if !isActive {
                Button(String(localized: "Set as Active")) {
                    settings.activeProviderID = provider.id
                }
            }
            Button(String(localized: "Remove")) {
                paneModel.pendingRemoval = provider
            }
        }
        .accessibilityIdentifier("settings-ai-provider-\(provider.id.uuidString)")
    }

    private var showsAppleIntelligence: Bool {
        if settings.useAppleIntelligence { return true }
        switch appleIntelligence {
        case nil, .unavailable(.requiresNewerMacOS), .unavailable(.deviceNotEligible):
            return false
        default:
            return true
        }
    }

    private var appleIntelligenceSection: some View {
        Section {
            Toggle(isOn: $settings.useAppleIntelligence) {
                Text("Use for inline suggestions and query actions")
                if let appleIntelligence {
                    Text(verbatim: appleIntelligence.unavailableExplanation
                        ?? String(localized: "Runs on this Mac and sends nothing over the network. Chat and Agent mode keep the active provider."))
                }
            }
            .disabled(appleIntelligence?.isAvailable == false && !settings.useAppleIntelligence)
            .accessibilityIdentifier("settings-ai-apple-intelligence")
        } header: {
            Text(verbatim: AppleIntelligenceAvailability.displayName)
        }
    }

    private var canSuggestInline: Bool {
        settings.hasActiveProvider || settings.useAppleIntelligence
    }

    private var inlineSuggestionsSection: some View {
        Section {
            Toggle(isOn: $settings.inlineSuggestionsEnabled) {
                Text("Suggest SQL while typing")
                if canSuggestInline {
                    Text("Press Tab to accept, Escape to dismiss.")
                } else {
                    Text("Choose an active provider or turn on Apple Intelligence first.")
                }
            }
            .disabled(!canSuggestInline && !settings.inlineSuggestionsEnabled)
            .accessibilityIdentifier("settings-ai-inline")

            SettingsNumberField(
                "Delay",
                value: debounceBinding,
                range: AISettings.inlineSuggestionDebounceRange,
                step: 50,
                unit: "ms",
                identifier: "settings-ai-inline-delay"
            )
            .disabled(!settings.inlineSuggestionsEnabled)
        } header: {
            Text("Inline Suggestions")
        }
    }

    private var debounceBinding: Binding<Int> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.clampedInlineSuggestionDebounceMs },
            set: { settings.wrappedValue.inlineSuggestionDebounceMs = $0 }
        )
    }

    private var agentSection: some View {
        Section {
            Toggle(isOn: $settings.maxToolRoundtripsEnabled) {
                Text("Limit tool calls per reply")
                Text("Agent mode pauses at the limit so you can continue. A higher limit uses more tokens per reply.")
            }
            .accessibilityIdentifier("settings-ai-tool-limit-enabled")

            SettingsNumberField(
                "Tool call limit",
                value: toolLimitBinding,
                range: AISettings.maxToolRoundtripsRange,
                step: 5,
                identifier: "settings-ai-tool-limit"
            )
            .disabled(!settings.maxToolRoundtripsEnabled)
        } header: {
            Text("Agent")
        }
    }

    private var toolLimitBinding: Binding<Int> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.clampedMaxToolRoundtrips },
            set: { settings.wrappedValue.maxToolRoundtrips = $0 }
        )
    }

    private var contextSection: some View {
        Section {
            Toggle("Include database schema", isOn: $settings.includeSchema)
                .accessibilityIdentifier("settings-ai-include-schema")
            SettingsNumberField(
                "Maximum tables",
                subtitle: "Used for chat context, {{schema}} commands and Copilot suggestions.",
                value: maxTablesBinding,
                range: AISettings.maxSchemaTablesRange,
                step: 1,
                identifier: "settings-ai-max-tables"
            )
            Toggle("Include current query", isOn: $settings.includeCurrentQuery)
                .accessibilityIdentifier("settings-ai-include-query")
            Toggle("Include query results", isOn: $settings.includeQueryResults)
                .accessibilityIdentifier("settings-ai-include-results")
        } header: {
            Text("Context")
        }
    }

    private var maxTablesBinding: Binding<Int> {
        let settings = $settings
        return Binding(
            get: { settings.wrappedValue.clampedMaxSchemaTables },
            set: { settings.wrappedValue.maxSchemaTables = $0 }
        )
    }

    // Shown with AI off too: MCP clients read the same policy.
    private var privacySection: some View {
        Section {
            Picker(selection: $settings.defaultConnectionPolicy) {
                ForEach(AIConnectionPolicy.allCases) { policy in
                    Text(verbatim: policy.displayName).tag(policy)
                }
            } label: {
                Text("Default AI policy")
                Text("Applies to connections set to Use Default, in AI features and for MCP clients.")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-ai-connection-access")
        } header: {
            Text("Privacy")
        }
    }
}

private struct SlashCommandsDrillRow: View {
    @ObservedObject var storage: CustomSlashCommandStorage

    var body: some View {
        SettingsDrillRow(
            route: SettingsRoute.page(.slashCommands),
            title: SettingsPage.slashCommands.title,
            value: SettingsFormat.count(storage.commands.count)
        )
    }
}

// Each row observes only the service its own status comes from, and starts nothing.
private struct AIProviderRow: View {
    let provider: AIProviderConfig
    let isActive: Bool
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 10) {
            BrandIconView(icon: provider.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.displayName)
                AIProviderRowStatus(provider: provider, hasKey: hasKey)
                    .font(.subheadline)
            }
            Spacer(minLength: 8)
            if isActive {
                Text("Active")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AIProviderRowStatus: View {
    let provider: AIProviderConfig
    let hasKey: Bool

    var body: some View {
        switch provider.type {
        case .copilot:
            CopilotRowStatus(provider: provider)
        case .chatgptCodex:
            ChatGPTRowStatus(provider: provider)
        case .claudeAgent:
            ClaudeAgentRowStatus(provider: provider)
        default:
            AIProviderStatusLabel(
                status: AIProviderStatus.resolve(
                    provider: provider,
                    hasAPIKey: hasKey,
                    oauthState: nil,
                    serviceError: nil,
                    claudeAgent: .unknown
                ),
                showsReadySymbol: false
            )
        }
    }
}

private struct CopilotRowStatus: View {
    let provider: AIProviderConfig
    @ObservedObject private var copilot = CopilotService.shared

    var body: some View {
        AIProviderStatusLabel(status: status, showsReadySymbol: false)
    }

    // The sign-in is known only once the language server answers; a server stopped after that keeps its answer.
    private var status: AIProviderStatus {
        var serviceError = copilot.statusMessage
        if case .error(let message) = copilot.status {
            serviceError = message
        }
        let reported = copilot.hasReportedAuthState && copilot.status != .starting
        return AIProviderStatus.resolve(
            provider: provider,
            hasAPIKey: false,
            oauthState: reported ? copilot.oauthState : nil,
            serviceError: serviceError,
            claudeAgent: .unknown,
            serviceStopped: copilot.status == .stopped
        )
    }
}

private struct ChatGPTRowStatus: View {
    let provider: AIProviderConfig
    @ObservedObject private var service = ChatGPTCodexService.shared

    var body: some View {
        AIProviderStatusLabel(
            status: AIProviderStatus.resolve(
                provider: provider,
                hasAPIKey: false,
                oauthState: service.oauthState,
                serviceError: service.errorMessage,
                claudeAgent: .unknown
            ),
            showsReadySymbol: false
        )
    }
}

private struct ClaudeAgentRowStatus: View {
    let provider: AIProviderConfig
    @ObservedObject private var service = ClaudeAgentService.shared

    var body: some View {
        AIProviderStatusLabel(
            status: AIProviderStatus.resolve(
                provider: provider,
                hasAPIKey: false,
                oauthState: nil,
                serviceError: nil,
                claudeAgent: service.state
            ),
            showsReadySymbol: false
        )
    }
}
