//
//  AIProviderDetailSheet.swift
//  TablePro
//
//  Drill-down detail sheet for configuring a single AI provider.
//

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
                        onSave(draft, apiKey)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isSaveEnabled)
                }
            }
            .onAppear {
                if draft.type == .copilot {
                    Task { await ensureCopilotRunning() }
                }
                fetchModels()
            }
            .onDisappear {
                cancelTasks()
            }
        }
        .frame(minWidth: 520, minHeight: 480)
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
        case .oauth, .none:
            return true
        }
    }

    // MARK: - Auth

    @ViewBuilder
    private var authSection: some View {
        switch draft.type.authStyle {
        case .apiKey:
            apiKeyAuthSection
        case .oauth:
            copilotAuthSection
        case .none:
            EmptyView()
        }
    }

    private var apiKeyAuthSection: some View {
        Section {
            SecureField(String(localized: "API Key"), text: $apiKey)
                .textFieldStyle(.roundedBorder)
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
            Text("Authentication")
        }
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
                if draft.type == .custom {
                    TextField(String(localized: "Name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                if draft.type != .copilot {
                    TextField(String(localized: "Endpoint"), text: $draft.endpoint)
                        .textFieldStyle(.roundedBorder)
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

    private var shouldShowConnectionSection: Bool {
        draft.type != .copilot
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            HStack {
                Text("Model")
                Spacer()
                modelControl
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
        } header: {
            Text("Model")
        }
    }

    @ViewBuilder
    private var modelControl: some View {
        if isFetchingModels {
            ProgressView().controlSize(.small)
        } else if fetchedModels.isEmpty {
            HStack(spacing: 6) {
                if !draft.model.isEmpty {
                    Text(draft.model)
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "Reload")) {
                    fetchModels()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        } else {
            Picker("", selection: $draft.model) {
                if draft.model.isEmpty {
                    Text(String(localized: "Select a model")).tag("")
                }
                ForEach(fetchedModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            HStack {
                Text("Max output tokens")
                Spacer()
                TextField("", text: maxOutputTokensBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
            if draft.type == .copilot {
                Toggle("Send telemetry to GitHub", isOn: $draft.telemetryEnabled)
            }
        } header: {
            Text("Advanced")
        }
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
                onDelete()
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
        if draft.type.authStyle == .apiKey,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fetchedModels = []
            modelFetchError = nil
            return
        }

        let provider = AIProviderFactory.createProvider(for: draft, apiKey: apiKey)
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

        let provider = AIProviderFactory.createProvider(for: draft, apiKey: apiKey)
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
