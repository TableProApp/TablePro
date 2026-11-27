import Combine
import SwiftUI

// One provider's live settings. Opening it never writes: only a user edit commits, one whole-provider write at a time.
struct AIProviderPage: View {
    let providerID: UUID
    @ObservedObject var slice: SettingsSlice<AISettings>

    @EnvironmentObject private var paneModel: AISettingsPaneModel
    @StateObject private var loader = AIModelListLoader()
    @State private var loadedKey: String?
    @State private var loadToken = 0
    @State private var choseOtherModel = false
    @State private var isEditingConnection = false

    var body: some View {
        Group {
            if let provider = slice.value.provider(withID: providerID) {
                form(provider)
            } else {
                UnavailableStateView(String(localized: "This provider was removed."), systemImage: "sparkles")
            }
        }
        .task(id: loadToken) {
            await loadModels()
        }
        .task {
            guard slice.value.enabled, let type = slice.value.provider(withID: providerID)?.type else { return }
            await paneModel.refreshAccounts(AIProviderAccountProbes.probedTypes.intersection([type]))
        }
        .onDisappear {
            CopilotService.shared.stopIfDisallowed(by: slice.value)
        }
        .sheet(isPresented: $isEditingConnection) {
            if let provider = slice.value.provider(withID: providerID) {
                AIProviderConnectionSheet(provider: provider, slice: slice) { saved in
                    loadedKey = nil
                    paneModel.setHasKey(saved.hasKey, for: providerID)
                    if saved.connectionChanged {
                        loadToken += 1
                    }
                }
            }
        }
    }

    private func form(_ provider: AIProviderConfig) -> some View {
        let descriptor = AIProviderRegistry.shared.descriptor(for: provider.type.rawValue)
        let showsAdvanced = descriptor?.allowsMaxOutputTokens == true || descriptor?.showsTelemetryToggle == true
        return Form {
            if !provider.authStyle.usesAPIKey {
                AIProviderAccountSections(type: provider.type)
            }
            if showsConnection(provider, descriptor: descriptor) {
                connectionSection(provider, descriptor: descriptor)
            }
            modelSection(provider, descriptor: descriptor, isLast: !showsAdvanced)
            if showsAdvanced {
                advancedSection(provider, descriptor: descriptor)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-page-ai-provider")
    }

    // A search result can open this page with AI off, which starts no service and sends no key.
    private func loadModels() async {
        guard slice.value.enabled, let provider = slice.value.provider(withID: providerID) else { return }
        if provider.type == .copilot, CopilotLifecycle.allowsRunning(slice.value) {
            await CopilotService.shared.start()
        }
        var key = ""
        if provider.authStyle.usesAPIKey {
            key = await AIProviderKeychain.key(for: providerID) ?? ""
            loadedKey = key
            paneModel.setHasKey(!key.isEmpty, for: providerID)
        }
        guard let current = slice.value.provider(withID: providerID) else { return }
        await loader.load(config: current, apiKey: key)
        guard loader.isCurrent, loader.error == nil else { return }
        switch AIProviderDraftRules.catalogUpdate(listIsCurrent: true, listIsEmpty: loader.models.isEmpty, connectionChanged: false) {
        case .store:
            AIModelCatalog.shared.store(providerID: providerID, models: loader.models)
        case .remove:
            AIModelCatalog.shared.remove(providerID: providerID)
        case .refetch, .keep:
            break
        }
    }

    private func commit(_ change: (inout AIProviderConfig) -> Void) {
        guard var updated = slice.value.provider(withID: providerID) else { return }
        let original = updated
        change(&updated)
        guard updated != original else { return }
        slice.value = slice.value.replacingProvider(updated)
        AIProviderFactory.invalidateCache(for: providerID)
        AppEvents.shared.aiProviderSaved.send(providerID)
    }

    private func hasKey(_ provider: AIProviderConfig) -> Bool {
        if let loadedKey { return !loadedKey.isEmpty }
        return paneModel.hasKey(provider.id)
    }

    private func showsConnection(_ provider: AIProviderConfig, descriptor: AIProviderDescriptor?) -> Bool {
        descriptor?.allowsNameConfiguration == true
            || descriptor?.allowsEndpointConfiguration == true
            || provider.authStyle.usesAPIKey
    }

    private func connectionSection(_ provider: AIProviderConfig, descriptor: AIProviderDescriptor?) -> some View {
        Section {
            if descriptor?.allowsNameConfiguration == true {
                LabeledContent("Name") {
                    Text(verbatim: provider.displayName)
                }
            }
            if descriptor?.allowsEndpointConfiguration == true {
                LabeledContent("Base URL") {
                    Text(verbatim: provider.endpoint)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(provider.endpoint)
                }
            }
            if provider.authStyle.usesAPIKey {
                LabeledContent("API key") {
                    hasKey(provider) ? Text("Set") : Text("Not set")
                }
            }
            if let caution = cleartextCaution(provider) {
                NoticeLabel(caution)
            }
        } header: {
            Text("Connection")
        } footer: {
            SettingsSectionActions {
                Button("Edit Connection…") {
                    isEditingConnection = true
                }
                .accessibilityIdentifier("ai-provider-edit-connection")
            }
        }
    }

    private func cleartextCaution(_ provider: AIProviderConfig) -> String? {
        guard AIEndpoint(provider.endpoint, style: provider.type.endpointStyle)?.isPlaintextToRemoteHost == true else {
            return nil
        }
        guard provider.authStyle.usesAPIKey, hasKey(provider) else {
            return String(localized: "Requests to this host are sent unencrypted over http.")
        }
        return String(localized: "Your API key is sent unencrypted over http to this host.")
    }

    private func modelSection(
        _ provider: AIProviderConfig,
        descriptor: AIProviderDescriptor?,
        isLast: Bool
    ) -> some View {
        let choices = AIModelChoices(models: loader.models)
        let selection = choices.selection(for: provider.model, choseOther: choseOtherModel)
        let reasoning = reasoning(for: provider, modelID: provider.model, descriptor: descriptor)
        return Section {
            Picker(selection: selectionBinding(choices: choices, descriptor: descriptor)) {
                AIModelPickerItems(choices: choices)
            } label: {
                Text("Model")
                AIModelListSubtitle(loader: loader)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("ai-provider-model")

            if selection == .custom {
                SettingsTextField(
                    "Model ID",
                    text: modelIDBinding(descriptor: descriptor),
                    prompt: Text(verbatim: "model-id"),
                    normalize: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
                .accessibilityIdentifier("ai-provider-model-id")
            }
            if descriptor?.supportsReasoning == true, !reasoning.effortLevels.isEmpty || reasoning.canTurnOff {
                Picker(selection: reasoningBinding(reasoning)) {
                    AIReasoningPickerItems(reasoning: reasoning)
                } label: {
                    Text("Reasoning")
                }
                .pickerStyle(.menu)
            }
            if descriptor?.fetchesModelList == true {
                LabeledContent("Model list") {
                    Button("Reload") {
                        loadToken += 1
                    }
                    .disabled(loader.isLoading)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            if isLast {
                removeAction(provider)
            }
        }
    }

    private func advancedSection(_ provider: AIProviderConfig, descriptor: AIProviderDescriptor?) -> some View {
        Section {
            if descriptor?.allowsMaxOutputTokens == true {
                SettingsTextField(
                    "Maximum output tokens",
                    text: maxOutputTokensBinding,
                    prompt: Text("Default"),
                    validate: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, SettingsIntegerInput.parse(trimmed) == nil else { return nil }
                        return String(localized: "Enter a whole number.")
                    },
                    normalize: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
            }
            if descriptor?.showsTelemetryToggle == true {
                Toggle("Send telemetry to GitHub", isOn: telemetryBinding)
            }
        } header: {
            Text("Advanced")
        } footer: {
            removeAction(provider)
        }
    }

    private func removeAction(_ provider: AIProviderConfig) -> some View {
        SettingsSectionActions {
            Button(String(localized: "Remove Provider…"), role: .destructive) {
                paneModel.pendingRemoval = provider
            }
            .accessibilityIdentifier("ai-provider-remove")
        }
    }

    private func reasoning(
        for provider: AIProviderConfig,
        modelID: String,
        descriptor: AIProviderDescriptor?
    ) -> AIReasoningSupport {
        let info = loader.models.first { $0.id == modelID }
            ?? AIModelCatalog.shared.info(providerID: provider.id, source: AIModelSource(config: provider), modelID: modelID)
        return descriptor?.reasoning(for: info) ?? .unsupported
    }

    // The model and the effort it allows change together, in one write.
    private func selectModel(_ id: String, picked: Bool, descriptor: AIProviderDescriptor?) {
        commit { provider in
            let current = provider.reasoningEffort
            let reasoning = reasoning(for: provider, modelID: id, descriptor: descriptor)
            provider.reasoningEffort = picked
                ? AIProviderDraftRules.effort(afterPicking: current, reasoning: reasoning)
                : AIProviderDraftRules.effort(keeping: current, reasoning: reasoning)
            provider.model = id
        }
    }

    private func selectionBinding(choices: AIModelChoices, descriptor: AIProviderDescriptor?) -> Binding<AIModelSelection> {
        let slice = slice
        let providerID = providerID
        let choseOther = choseOtherModel
        return Binding(
            get: { choices.selection(for: slice.value.provider(withID: providerID)?.model ?? "", choseOther: choseOther) },
            set: { selection in
                switch selection {
                case .model(let id):
                    choseOtherModel = false
                    selectModel(id, picked: true, descriptor: descriptor)
                case .custom:
                    choseOtherModel = true
                }
            }
        )
    }

    // An empty Model ID is never committed: the field reads the saved model back.
    private func modelIDBinding(descriptor: AIProviderDescriptor?) -> Binding<String> {
        let slice = slice
        let providerID = providerID
        return Binding(
            get: { slice.value.provider(withID: providerID)?.model ?? "" },
            set: { typed in
                let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                selectModel(trimmed, picked: false, descriptor: descriptor)
            }
        )
    }

    private func reasoningBinding(_ reasoning: AIReasoningSupport) -> Binding<ReasoningEffort?> {
        let slice = slice
        let providerID = providerID
        return Binding(
            get: {
                AIProviderDraftRules.displayedEffort(
                    slice.value.provider(withID: providerID)?.reasoningEffort,
                    reasoning: reasoning
                )
            },
            set: { effort in
                commit { $0.reasoningEffort = effort }
            }
        )
    }

    private var maxOutputTokensBinding: Binding<String> {
        let slice = slice
        let providerID = providerID
        return Binding(
            get: { slice.value.provider(withID: providerID)?.maxOutputTokens.map(String.init) ?? "" },
            set: { typed in
                let value = AIProviderEditorModel.maxOutputTokens(from: typed)
                commit { $0.maxOutputTokens = value }
            }
        )
    }

    private var telemetryBinding: Binding<Bool> {
        let slice = slice
        let providerID = providerID
        return Binding(
            get: { slice.value.provider(withID: providerID)?.telemetryEnabled ?? false },
            set: { enabled in
                commit { $0.telemetryEnabled = enabled }
            }
        )
    }
}
