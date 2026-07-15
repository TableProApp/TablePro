//
//  AIProviderDetailSheet.swift
//  TablePro
//
//  Drill-down detail sheet for configuring a single AI provider.
//

import AppKit
import SwiftUI

struct AIProviderDetailSheet: View {
    let isNew: Bool
    let onSave: (AIProviderConfig, String) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var draft: AIProviderConfig
    @State private var apiKey: String
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelFetchError: String?
    @State private var modelFetchTask: Task<Void, Never>?

    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var testTask: Task<Void, Never>?

    @State private var copilotService = CopilotService.shared
    @State private var copilotErrorMessage: String?

    @State private var chatGPTCodexService = ChatGPTCodexService.shared

    @State private var cursorAgentService = CursorAgentService.shared

    @State private var xaiService = XAIService.shared

    @State private var showRemoveConfirmation = false

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    init(
        provider: AIProviderConfig,
        initialAPIKey: String,
        isNew: Bool,
        onSave: @escaping (AIProviderConfig, String) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self._draft = State(initialValue: provider)
        self._apiKey = State(initialValue: initialAPIKey)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                authSection
                connectionSection
                modelSection
                advancedSection
                if let onDelete, !isNew {
                    deleteSection(onDelete: onDelete)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        cancelTasks()
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        cancelTasks()
                        onSave(normalizedDraft, apiKey)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isSaveEnabled)
                }
            }
            .onAppear {
                if draft.type == .copilot {
                    Task {
                        await ensureCopilotRunning()
                        fetchModels()
                    }
                } else {
                    if draft.type == .chatgptCodex {
                        Task { await chatGPTCodexService.refreshAuthState() }
                    }
                    if draft.type == .cursor {
                        Task { await cursorAgentService.refreshStatus() }
                    }
                    if draft.type == .xai {
                        Task { await xaiService.refreshAuthState() }
                    }
                    fetchModels()
                }
            }
            .onDisappear {
                cancelTasks()
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .confirmationDialog(
            String(format: String(localized: "Remove “%@”?"), draft.displayName),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove Provider"), role: .destructive) {
                onDelete?()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The provider configuration and stored API key will be deleted."))
        }
    }

    private var navigationTitle: String {
        if isNew {
            return String(format: String(localized: "Add %@"), draft.type.displayName)
        }
        return draft.displayName
    }

    private var isSaveEnabled: Bool {
        switch draft.type.authStyle {
        case .apiKey:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .optionalApiKey, .oauth, .none:
            return true
        }
    }

    private var normalizedDraft: AIProviderConfig {
        var provider = draft
        provider.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider
    }

    // MARK: - Auth

    @ViewBuilder
    private var authSection: some View {
        switch draft.type.authStyle {
        case .apiKey, .optionalApiKey:
            if draft.type == .cursor {
                cursorAuthSection
            } else if draft.type == .xai {
                xaiAuthSection
            } else {
                apiKeyAuthSection
            }
        case .oauth:
            switch descriptor?.oauthFlowKind {
            case .deviceCode:
                copilotAuthSection
            case .browserRedirect:
                chatGPTCodexAuthSection
            case .none:
                EmptyView()
            }
        case .none:
            EmptyView()
        }
    }

    private var apiKeyAuthSection: some View {
        Section {
            SecureField(String(localized: "API Key"), text: $apiKey)
                .onChange(of: apiKey) {
                    testResult = nil
                }
            HStack {
                Spacer()
                Button {
                    testProvider()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || (draft.type.authStyle == .apiKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            if case .success = testResult {
                Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if case .failure(let message) = testResult {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
            }
        } header: {
            Text("Authentication")
        }
    }

    @ViewBuilder
    private var cursorAuthSection: some View {
        cursorAPIKeySection
        cursorSignInSection
    }

    private var cursorAPIKeySection: some View {
        Section {
            SecureField(String(localized: "API Key"), text: $apiKey)
                .onChange(of: apiKey) { testResult = nil }
            HStack {
                Spacer()
                Button {
                    testProvider()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .success = testResult {
                Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if case .failure(let message) = testResult {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Optional. A key from the Cursor dashboard is used instead of signing in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cursorSignInSection: some View {
        Section {
            cursorSignInContent
            if let message = cursorAgentService.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(3)
            }
        } header: {
            Text("Sign in with Cursor")
        } footer: {
            Text("Use your Cursor subscription with no API key. Requires the Cursor CLI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cursorSignInContent: some View {
        switch cursorAgentService.authState {
        case .notInstalled:
            LabeledContent {
                Button {
                    copyToPasteboard(CursorAgentCLI.installCommand)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy install command"))
            } label: {
                Text(CursorAgentCLI.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("The Cursor CLI is not installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Recheck")) {
                    Task { await cursorAgentService.refreshStatus() }
                }
                .controlSize(.small)
            }

        case .signedOut:
            HStack {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Sign in with Cursor")) {
                    cursorAgentService.signIn()
                }
                .buttonStyle(.borderedProminent)
            }

        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening your browser to sign in…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Cancel")) {
                    cursorAgentService.cancelSignIn()
                }
                .controlSize(.small)
            }

        case .signedIn(let account):
            LabeledContent {
                Button(String(localized: "Sign Out")) {
                    Task { await cursorAgentService.signOut() }
                }
            } label: {
                Label(
                    account.isEmpty
                        ? String(localized: "Signed in")
                        : String(format: String(localized: "Signed in as %@"), account),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var xaiAuthSection: some View {
        xaiAPIKeySection
        xaiSignInSection
    }

    private var xaiAPIKeySection: some View {
        Section {
            SecureField(String(localized: "API Key"), text: $apiKey)
                .onChange(of: apiKey) { testResult = nil }
            HStack {
                Spacer()
                Button {
                    testProvider()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .success = testResult {
                Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if case .failure(let message) = testResult {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("A key from the xAI Console bills xAI API credits. Grok 4.5 and Grok 4.3 are available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var xaiSignInSection: some View {
        Section {
            xaiSignInContent
            if let message = xaiService.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(3)
            }
        } header: {
            Text("Sign in with xAI")
        } footer: {
            Text("Use your SuperGrok or X Premium+ subscription with no API key. Sign-in opens the Grok Build consent screen. This is an unofficial interface that may change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var xaiSignInContent: some View {
        switch xaiService.authState {
        case .signedOut:
            HStack {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Sign in with xAI")) {
                    Task { await xaiService.signIn() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening your browser to sign in…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .signedIn(let email):
            LabeledContent {
                Button(String(localized: "Sign Out")) {
                    Task { await xaiService.signOut() }
                }
            } label: {
                Label(
                    email.isEmpty
                        ? String(localized: "Signed in")
                        : String(format: String(localized: "Signed in as %@"), email),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var copilotAuthSection: some View {
        Section {
            switch copilotService.authState {
            case .signedOut:
                signInRow

            case .signingIn(let userCode, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code on GitHub:")
                    Text(userCode)
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.bold)
                        .textSelection(.enabled)
                    Text("The code has been copied to your clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("The code expires in 15 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Complete Sign In") {
                            Task { await completeCopilotSignIn() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel"), role: .cancel) {
                            Task { await copilotService.signOut() }
                        }
                    }
                }

            case .signedIn(let username):
                HStack {
                    Label(
                        String(format: String(localized: "Signed in as %@"), username),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Spacer()
                    Button(String(localized: "Sign Out")) {
                        Task { await copilotService.signOut() }
                    }
                }
            }

            if let copilotErrorMessage {
                Text(copilotErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            statusRow
        } header: {
            Text("Account")
        }
    }

    private var signInRow: some View {
        HStack {
            Text("Authentication required")
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Sign in with GitHub")) {
                Task { await copilotSignIn() }
            }
            .disabled(copilotService.status != .running)
        }
    }

    private var chatGPTCodexAuthSection: some View {
        Section {
            switch chatGPTCodexService.authState {
            case .signedOut:
                chatGPTCodexSignInRows

            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening your browser to sign in…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .signedIn(let email, let planType):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(chatGPTCodexSignedInLabel(email: email), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(String(localized: "Sign Out")) {
                            Task { await chatGPTCodexService.signOut() }
                        }
                    }
                    if let planType, !planType.isEmpty {
                        Text(String(format: String(localized: "Plan: %@"), planType))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = chatGPTCodexService.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Access uses your ChatGPT subscription (Plus, Pro, Business, or Enterprise) and follows OpenAI's terms. This is an unofficial interface that may change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chatGPTCodexSignInRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sign in to use your ChatGPT subscription")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Sign in with ChatGPT")) {
                    Task { await chatGPTCodexService.signIn() }
                }
                .buttonStyle(.borderedProminent)
            }
            Button(String(localized: "Import from Codex CLI")) {
                Task { await chatGPTCodexService.importFromCodexCLI() }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func chatGPTCodexSignedInLabel(email: String) -> String {
        email.isEmpty
            ? String(localized: "Signed in")
            : String(format: String(localized: "Signed in as %@"), email)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch copilotService.status {
        case .stopped:
            Label("Service stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting service…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .running:
            EmptyView()
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        if shouldShowConnectionSection {
            Section {
                if allowsNameField {
                    TextField(String(localized: "Name"), text: $draft.name)
                }
                if allowsEndpointField {
                    TextField(String(localized: "Endpoint"), text: $draft.endpoint)
                        .onChange(of: draft.endpoint) {
                            scheduleFetchModels()
                            testResult = nil
                        }
                }
            } header: {
                Text("Connection")
            }
        }
    }

    private var allowsNameField: Bool {
        descriptor?.allowsNameConfiguration == true
    }

    private var allowsEndpointField: Bool {
        descriptor?.allowsEndpointConfiguration == true
    }

    private var shouldShowConnectionSection: Bool {
        allowsNameField || allowsEndpointField
    }

    // MARK: - Model

    private var descriptor: AIProviderDescriptor? {
        AIProviderRegistry.shared.descriptor(for: draft.type.rawValue)
    }

    private var curatedModels: [CuratedModel] {
        descriptor?.curatedModels ?? []
    }

    private var effortLevelsForCurrentModel: [ReasoningEffort] {
        descriptor?.supportedEffortLevels(forModelID: draft.model) ?? []
    }

    private var showsReasoningPicker: Bool {
        guard descriptor?.supportsReasoning == true else { return false }
        return !effortLevelsForCurrentModel.isEmpty
    }

    private var isCustomModel: Bool {
        !curatedModels.contains(where: { $0.id == draft.model })
            && !fetchedModels.contains(draft.model)
    }

    private var modelSection: some View {
        Section {
            modelPicker
            if isCustomModel {
                TextField(String(localized: "Model ID"), text: $draft.model)
                    .textFieldStyle(.roundedBorder)
            }
            if showsReasoningPicker {
                reasoningPicker
            }
            modelFetchStatus
        } header: {
            Text("Model")
        }
    }

    private var modelPicker: some View {
        Picker(String(localized: "Model"), selection: modelSelectionBinding) {
            if !curatedModels.isEmpty {
                Section {
                    ForEach(curatedModels) { model in
                        Text(model.displayName).tag(ModelSelection.curated(model.id))
                    }
                }
            }
            let fetchedFiltered = fetchedModels.filter { id in
                !curatedModels.contains(where: { $0.id == id })
            }
            if !fetchedFiltered.isEmpty {
                Section {
                    ForEach(fetchedFiltered, id: \.self) { id in
                        Text(id).tag(ModelSelection.fetched(id))
                    }
                }
            }
            Text(String(localized: "Other…")).tag(ModelSelection.custom)
        }
        .pickerStyle(.menu)
    }

    private enum ModelSelection: Hashable {
        case curated(String)
        case fetched(String)
        case custom
    }

    private var modelSelectionBinding: Binding<ModelSelection> {
        Binding<ModelSelection>(
            get: {
                if curatedModels.contains(where: { $0.id == draft.model }) {
                    return .curated(draft.model)
                }
                if fetchedModels.contains(draft.model) {
                    return .fetched(draft.model)
                }
                return .custom
            },
            set: { newValue in
                switch newValue {
                case .curated(let id):
                    draft.model = id
                    if let curated = curatedModels.first(where: { $0.id == id }) {
                        if let defaultEffort = curated.defaultEffort, draft.reasoningEffort == nil {
                            draft.reasoningEffort = defaultEffort
                        }
                        let supported = Set(curated.supportedEffortLevels)
                        if let currentEffort = draft.reasoningEffort, !supported.contains(currentEffort) {
                            draft.reasoningEffort = curated.defaultEffort
                        }
                    }
                case .fetched(let id):
                    draft.model = id
                case .custom:
                    if curatedModels.contains(where: { $0.id == draft.model }) || fetchedModels.contains(draft.model) {
                        draft.model = ""
                    }
                }
            }
        )
    }

    private var reasoningPicker: some View {
        Picker(String(localized: "Reasoning"), selection: $draft.reasoningEffort) {
            Text(String(localized: "Off")).tag(ReasoningEffort?.none)
            ForEach(effortLevelsForCurrentModel) { effort in
                Text(effort.displayName).tag(Optional(effort))
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var modelFetchStatus: some View {
        if isFetchingModels {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Fetching models…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let modelFetchError {
            HStack {
                Text(modelFetchError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button(String(localized: "Reload")) {
                    fetchModels()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        if showsMaxOutputTokens || showsTelemetryToggle {
            Section {
                if showsMaxOutputTokens {
                    HStack {
                        Text("Max output tokens")
                        Spacer()
                        TextField("", text: maxOutputTokensBinding)
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if showsTelemetryToggle {
                    Toggle("Send telemetry to GitHub", isOn: $draft.telemetryEnabled)
                }
            } header: {
                Text("Advanced")
            }
        }
    }

    private var showsMaxOutputTokens: Bool {
        descriptor?.allowsMaxOutputTokens == true
    }

    private var showsTelemetryToggle: Bool {
        descriptor?.showsTelemetryToggle == true
    }

    private var maxOutputTokensBinding: Binding<String> {
        Binding<String>(
            get: {
                guard let value = draft.maxOutputTokens else { return "" }
                return String(value)
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    draft.maxOutputTokens = nil
                } else if let value = Int(trimmed), value > 0 {
                    draft.maxOutputTokens = value
                }
            }
        )
    }

    // MARK: - Delete

    private func deleteSection(onDelete: @escaping () -> Void) -> some View {
        Section {
            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label(String(localized: "Remove Provider"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Tasks

    private func cancelTasks() {
        modelFetchTask?.cancel()
        modelFetchTask = nil
        testTask?.cancel()
        testTask = nil
    }

    private func ensureCopilotRunning() async {
        if copilotService.status == .stopped {
            await copilotService.start()
        }
    }

    private func copilotSignIn() async {
        copilotErrorMessage = nil
        do {
            try await copilotService.signIn()
        } catch {
            copilotErrorMessage = error.localizedDescription
        }
    }

    private func completeCopilotSignIn() async {
        copilotErrorMessage = nil
        do {
            try await copilotService.completeSignIn()
        } catch {
            copilotErrorMessage = error.localizedDescription
        }
    }

    private func scheduleFetchModels() {
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            fetchModels()
        }
    }

    private func fetchModels() {
        guard descriptor?.fetchesModelList == true else {
            fetchedModels = []
            modelFetchError = nil
            if draft.model.isEmpty, let first = curatedModels.first {
                draft.model = first.id
            }
            return
        }
        if draft.type.authStyle == .apiKey,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fetchedModels = []
            modelFetchError = nil
            return
        }

        let provider = AIProviderFactory.createProvider(for: normalizedDraft, apiKey: apiKey)
        isFetchingModels = true
        modelFetchError = nil

        modelFetchTask?.cancel()
        modelFetchTask = Task {
            do {
                let models = try await provider.fetchAvailableModels()
                guard !Task.isCancelled else { return }
                fetchedModels = models
                if draft.model.isEmpty, let first = models.first {
                    draft.model = first
                }
                isFetchingModels = false
            } catch {
                guard !Task.isCancelled else { return }
                modelFetchError = error.localizedDescription
                isFetchingModels = false
            }
        }
    }

    func testProvider() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.type.authStyle == .apiKey, trimmed.isEmpty {
            testResult = .failure(String(localized: "API key is required"))
            return
        }

        let provider = AIProviderFactory.createProvider(for: normalizedDraft, apiKey: apiKey)
        isTesting = true
        testResult = nil

        testTask?.cancel()
        testTask = Task {
            do {
                let success = try await provider.testConnection()
                guard !Task.isCancelled else { return }
                isTesting = false
                testResult = success
                    ? .success
                    : .failure(String(localized: "Connection test failed"))
            } catch {
                guard !Task.isCancelled else { return }
                isTesting = false
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}
