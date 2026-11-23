import SwiftUI

struct AIProviderEditorParts: OptionSet {
    let rawValue: Int

    static let connection = AIProviderEditorParts(rawValue: 1 << 0)
    static let apiKey = AIProviderEditorParts(rawValue: 1 << 1)
    static let account = AIProviderEditorParts(rawValue: 1 << 2)
    static let model = AIProviderEditorParts(rawValue: 1 << 3)
    static let advanced = AIProviderEditorParts(rawValue: 1 << 4)

    static let all: AIProviderEditorParts = [.connection, .apiKey, .account, .model, .advanced]
}

// Shared by the Add Provider and Edit Connection sheets; every edit stays in the model's draft until Save.
struct AIProviderEditorSections: View {
    private enum Field: Hashable {
        case apiKey
        case endpoint
    }

    @ObservedObject private var model: AIProviderEditorModel
    @ObservedObject private var loader: AIModelListLoader
    private let parts: AIProviderEditorParts

    @FocusState private var focus: Field?
    @State private var focusedField: Field?

    init(model: AIProviderEditorModel, parts: AIProviderEditorParts) {
        self._model = ObservedObject(wrappedValue: model)
        self._loader = ObservedObject(wrappedValue: model.loader)
        self.parts = parts
    }

    var body: some View {
        Group {
            if parts.contains(.connection), model.allowsName || model.allowsEndpoint {
                connectionSection
            }
            if parts.contains(.apiKey), model.usesAPIKey {
                apiKeySection
            }
            if parts.contains(.account), !model.usesAPIKey {
                AIProviderAccountSections(type: model.draft.type)
            }
            if parts.contains(.model) {
                modelSection
            }
            if parts.contains(.advanced), model.showsMaxOutputTokens || model.showsTelemetryToggle {
                advancedSection
            }
        }
        .onChange(of: focus) { newFocus in
            // Leaving the key or Base URL field commits it, which is when the model list loads.
            if focusedField != nil, newFocus != focusedField {
                commitConnection()
            }
            focusedField = newFocus
        }
    }

    private func commitConnection() {
        guard parts.contains(.model) else { return }
        Task { await model.fetchModels() }
    }

    private var connectionSection: some View {
        Section {
            if model.allowsName {
                TextField(text: $model.draft.name, prompt: Text(verbatim: model.draft.kindName)) {
                    Text("Name")
                }
                .accessibilityIdentifier("ai-provider-name")
            }
            if model.allowsEndpoint {
                TextField(text: endpointBinding, prompt: Text(verbatim: endpointPrompt)) {
                    Text("Base URL")
                    Text("Include the version segment your server uses, such as /v1 or /v4.")
                }
                .focused($focus, equals: .endpoint)
                .onSubmit(commitConnection)
                .accessibilityIdentifier("ai-provider-base-url")

                if let url = model.resolvedChatURL {
                    LabeledContent("Requests go to") {
                        Text(verbatim: url)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(url)
                    }
                }
                if let caution = model.cleartextCaution {
                    NoticeLabel(caution)
                }
            }
        } header: {
            Text("Connection")
        }
    }

    private var endpointPrompt: String {
        model.draft.defaultEndpoint.isEmpty ? "https://" : model.draft.defaultEndpoint
    }

    private var endpointBinding: Binding<String> {
        let model = model
        return Binding(
            get: { model.draft.endpoint },
            set: { typed in
                guard typed != model.draft.endpoint else { return }
                model.draft.endpoint = typed
                model.connectionEdited()
            }
        )
    }

    private var apiKeySection: some View {
        Section {
            SecureField(text: keyBinding, prompt: model.draft.authStyle == .apiKey ? Text("Required") : Text("Optional")) {
                Text("API key")
            }
            .focused($focus, equals: .apiKey)
            .onSubmit(commitConnection)
            .disabled(!model.isKeyLoaded)
            .accessibilityIdentifier("ai-provider-api-key")

            LabeledContent {
                HStack(spacing: 6) {
                    if model.isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Button("Test Connection") {
                        model.test()
                    }
                    .disabled(!canTest)
                    .accessibilityIdentifier("ai-provider-test")
                }
            } label: {
                Text("Connection test")
                testResultLine
            }
        } header: {
            Text("Authentication")
        }
    }

    private var canTest: Bool {
        guard model.isKeyLoaded, !model.isTesting else { return false }
        guard model.draft.authStyle == .apiKey else { return true }
        return !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var testResultLine: some View {
        switch model.testResult {
        case .success:
            NoticeLabel(String(localized: "Connection successful"), severity: .success)
        case .failure(let message):
            NoticeLabel(message, severity: .error)
        case nil:
            if model.isTesting {
                Text("Testing…")
            } else {
                Text("Sends one short request with this key and Base URL.")
            }
        }
    }

    private var keyBinding: Binding<String> {
        let model = model
        return Binding(
            get: { model.apiKey },
            set: { model.editKey($0) }
        )
    }

    private var modelSection: some View {
        Section {
            Picker(selection: selectionBinding) {
                AIModelPickerItems(choices: model.choices)
            } label: {
                Text("Model")
                AIModelListSubtitle(loader: loader, needsChoice: model.needsModelChoice)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("ai-provider-model")

            if model.isCustomModel {
                TextField(text: typedModelBinding, prompt: Text(verbatim: "model-id")) {
                    Text("Model ID")
                }
            }
            if model.showsReasoningPicker {
                Picker(selection: $model.draft.reasoningEffort) {
                    AIReasoningPickerItems(reasoning: model.reasoningForCurrentModel)
                } label: {
                    Text("Reasoning")
                }
                .pickerStyle(.menu)
            }
            if model.fetchesModelList {
                LabeledContent("Model list") {
                    Button("Reload") {
                        Task { await model.fetchModels(force: true) }
                    }
                    .disabled(loader.isLoading)
                }
            }
        } header: {
            Text("Model")
        }
    }

    private var selectionBinding: Binding<AIModelSelection> {
        let model = model
        return Binding(
            get: { model.modelSelection },
            set: { model.select($0) }
        )
    }

    private var typedModelBinding: Binding<String> {
        let model = model
        return Binding(
            get: { model.draft.model },
            set: { model.typeModel($0) }
        )
    }

    private var advancedSection: some View {
        Section {
            if model.showsMaxOutputTokens {
                TextField(text: $model.maxOutputTokensText, prompt: Text("Default")) {
                    Text("Maximum output tokens")
                }
            }
            if model.showsTelemetryToggle {
                Toggle("Send telemetry to GitHub", isOn: $model.draft.telemetryEnabled)
            }
        } header: {
            Text("Advanced")
        }
    }
}

struct AIModelPickerItems: View {
    let choices: AIModelChoices

    var body: some View {
        if !choices.curated.isEmpty {
            Section {
                ForEach(choices.curated) { model in
                    Text(verbatim: model.displayName).tag(AIModelSelection.curated(model.id))
                }
            }
        }
        if !choices.fetched.isEmpty {
            Section {
                ForEach(choices.fetched, id: \.self) { id in
                    Text(verbatim: id).tag(AIModelSelection.fetched(id))
                }
            }
        }
        Text("Other…").tag(AIModelSelection.custom)
    }
}

struct AIReasoningPickerItems: View {
    let reasoning: AIReasoningSupport

    var body: some View {
        if !reasoning.isMandatory {
            Text("Off").tag(ReasoningEffort?.none)
        }
        ForEach(reasoning.effortLevels) { effort in
            Text(effort.displayName).tag(ReasoningEffort?.some(effort))
        }
    }
}

// The second line of the Model picker's label: one state at a time.
struct AIModelListSubtitle: View {
    @ObservedObject var loader: AIModelListLoader
    var needsChoice = false

    var body: some View {
        if loader.isLoading {
            Label {
                Text("Loading models…")
            } icon: {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
        } else if let error = loader.error {
            NoticeLabel(error, severity: .error)
        } else if loader.blocker == .missingAPIKey {
            Text("Add an API key to load this provider's models.")
        } else if needsChoice {
            Text("Pick a model to add this provider.")
        }
    }
}

// The sign-in part of an account-based provider, the same on the provider page and in the Add sheet.
struct AIProviderAccountSections: View {
    let type: AIProviderType

    var body: some View {
        switch type {
        case .copilot:
            CopilotAccountSection()
        case .chatgptCodex:
            ChatGPTAccountSection()
        case .claudeAgent:
            ClaudeAgentAccountSection()
        default:
            EmptyView()
        }
    }
}

private struct CopilotAccountSection: View {
    @ObservedObject private var copilot = CopilotService.shared
    @State private var signInError: String?

    var body: some View {
        Section {
            switch copilot.authState {
            case .signedOut:
                LabeledContent {
                    Button("Sign In…") {
                        Task { await signIn() }
                    }
                    .disabled(copilot.status != .running)
                } label: {
                    Text("GitHub account")
                    accountNote(otherwise: String(localized: "Not signed in"))
                }
            case .signingIn(let userCode, _):
                LabeledContent("Code") {
                    HStack(spacing: 8) {
                        Text(verbatim: userCode)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Button("Copy") {
                            ClipboardService.shared.writeText(userCode)
                        }
                    }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Cancel") {
                            Task { await copilot.signOut() }
                        }
                        Button("Complete Sign In") {
                            Task { await completeSignIn() }
                        }
                    }
                } label: {
                    Text("Enter the code on GitHub")
                    accountNote(otherwise: String(localized: "It was copied to the clipboard and expires in 15 minutes."))
                }
            case .signedIn(let username):
                LabeledContent {
                    Button("Sign Out") {
                        Task { await copilot.signOut() }
                    }
                } label: {
                    Text("GitHub account")
                    accountNote(otherwise: username)
                }
            }
        } header: {
            Text("GitHub Account")
        }
    }

    @ViewBuilder
    private func accountNote(otherwise fallback: String) -> some View {
        if let message = signInError ?? copilot.statusMessage {
            NoticeLabel(message, severity: .error)
        } else {
            switch copilot.status {
            case .starting:
                Label {
                    Text("Starting…")
                } icon: {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
            case .stopped where !copilot.authState.isSignedIn:
                Text("Not started")
            case .error(let message):
                NoticeLabel(message, severity: .error)
            default:
                Text(verbatim: fallback)
            }
        }
    }

    private func signIn() async {
        signInError = nil
        do {
            try await copilot.signIn()
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func completeSignIn() async {
        signInError = nil
        do {
            try await copilot.completeSignIn()
        } catch {
            signInError = error.localizedDescription
        }
    }
}

private struct ChatGPTAccountSection: View {
    @ObservedObject private var service = ChatGPTCodexService.shared

    var body: some View {
        Section {
            switch service.authState {
            case .signedOut:
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Import from Codex CLI") {
                            Task { await service.importFromCodexCLI() }
                        }
                        Button("Sign In…") {
                            Task { await service.signIn() }
                        }
                    }
                } label: {
                    Text("ChatGPT account")
                    accountNote(otherwise: String(localized: "Not signed in"))
                }
            case .signingIn:
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("ChatGPT account")
                    Label {
                        Text("Waiting for your browser…")
                    } icon: {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                }
            case .signedIn(let email, let planType):
                LabeledContent {
                    Button("Sign Out") {
                        Task { await service.signOut() }
                    }
                } label: {
                    Text("ChatGPT account")
                    accountNote(otherwise: email.isEmpty ? String(localized: "Signed in") : email)
                }
                if let planType, !planType.isEmpty {
                    LabeledContent("Plan") {
                        Text(verbatim: planType)
                    }
                }
            }
            SettingsHelpRow(
                "Uses your Plus, Pro, Business or Enterprise subscription under OpenAI's terms. This interface is unofficial and may change."
            )
        } header: {
            Text("ChatGPT Account")
        }
    }

    @ViewBuilder
    private func accountNote(otherwise fallback: String) -> some View {
        if let message = service.errorMessage {
            NoticeLabel(message, severity: .error)
        } else {
            Text(verbatim: fallback)
        }
    }
}

private struct ClaudeAgentAccountSection: View {
    @ObservedObject private var service = ClaudeAgentService.shared

    var body: some View {
        Section {
            LabeledContent {
                Button("Check Again") {
                    service.refreshStatus()
                }
                .disabled(service.isRefreshing)
            } label: {
                Text("Status")
                AIProviderStatusLabel(status: status)
            }
            if let plan {
                LabeledContent("Plan") {
                    Text(verbatim: plan)
                }
            }
            if let command = service.remedyCommand {
                LabeledContent {
                    Button("Copy") {
                        ClipboardService.shared.writeText(command)
                    }
                } label: {
                    Text(verbatim: command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    if let requirement {
                        Text(verbatim: requirement)
                    }
                }
            }
            SettingsHelpRow(
                "Runs the claude command line tool, so chat bills against your Claude subscription. Database tools need the MCP server, in Settings > MCP."
            )
        } header: {
            Text("Claude Agent")
        }

        ClaudeAgentDisclosureSection()
    }

    private var status: AIProviderStatus {
        AIProviderStatus.resolve(
            provider: AIProviderConfig(type: .claudeAgent),
            hasAPIKey: false,
            oauthState: nil,
            serviceError: nil,
            claudeAgent: service.state
        )
    }

    private var plan: String? {
        guard case .signedIn(_, let plan?) = service.state, !plan.isEmpty else { return nil }
        return plan
    }

    private var requirement: String? {
        guard case .outdated = service.state else { return nil }
        return String(format: String(localized: "Version %@ or newer is required."), ClaudeAgentCLI.minimumVersion)
    }
}
