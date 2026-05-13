//
//  AIChatPanelView.swift
//  TablePro
//
//  AI chat panel view - right-side panel for conversing with AI about database queries.
//

import SwiftUI

/// AI chat panel displayed alongside the main editor content
struct AIChatPanelView: View {
    private static let warningBackgroundOpacity: Double = 0.1

    let connection: DatabaseConnection
    var currentQuery: String?
    var queryResults: String?

    @Bindable var viewModel: AIChatViewModel
    private let settingsManager = AppSettingsManager.shared
    @State private var bottomVisibleMessageID: UUID?
    @State private var pinnedToBottom: Bool = true
    @State private var mentionState = MentionPopoverState()

    private var hasConfiguredProvider: Bool {
        settingsManager.ai.hasActiveProvider
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hasConfiguredProvider && viewModel.messages.isEmpty {
                noProviderState
            } else if viewModel.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            if hasConfiguredProvider {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                inputArea
            }
        }
        .onAppear {
            viewModel.connection = connection
        }
        .onChange(of: connection.id) {
            viewModel.connection = connection
        }
        .task(id: settingsManager.ai.providers.map(\.id)) {
            await viewModel.loadAvailableModels()
        }
        .task(id: connection.id) {
            await viewModel.loadSavedQueries()
        }
        .alert(
            String(localized: "Allow AI Access"),
            isPresented: $viewModel.showAIAccessConfirmation
        ) {
            Button(String(localized: "Allow")) {
                viewModel.confirmAIAccess()
            }
            Button(String(localized: "Don't Allow"), role: .cancel) {
                viewModel.denyAIAccess()
            }
        } message: {
            Text(String(localized: "Your database schema and query data will be sent to the AI provider for analysis. Allow for this connection?"))
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        EmptyStateView(
            icon: "sparkles",
            title: String(localized: "Ask AI about your database"),
            description: String(localized: "AI responses may be inaccurate")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noProviderState: some View {
        EmptyStateView(
            icon: "gear",
            title: String(localized: "AI Not Configured"),
            description: String(localized: "Configure an AI provider in Settings to start chatting."),
            actionTitle: String(localized: "Go to Settings…"),
            action: {
                WindowOpener.shared.openSettings(tab: .ai)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        let visibleMessages = viewModel.messages.filter { isVisibleInMessageList($0) }
        let spacedMessageIDs: Set<UUID> = {
            var ids = Set<UUID>()
            for i in 1..<visibleMessages.count
                where visibleMessages[i].role == .user && visibleMessages[i - 1].role == .assistant {
                ids.insert(visibleMessages[i].id)
            }
            return ids
        }()

        let lastMessageID = visibleMessages.last?.id
        let isUserScrolledUp = !pinnedToBottom && bottomVisibleMessageID != nil
            && bottomVisibleMessageID != lastMessageID

        return ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleMessages) { message in
                        if spacedMessageIDs.contains(message.id) {
                            Spacer()
                                .frame(height: 16)
                        }
                        AIChatMessageView(
                            message: message,
                            onRetry: shouldShowRetry(for: message) ? { viewModel.retry() } : nil,
                            onRegenerate: shouldShowRegenerate(for: message) ? { viewModel.regenerate() } : nil,
                            onEdit: message.role == .user && !viewModel.isStreaming
                                ? { viewModel.editMessage(message) } : nil
                        )
                        .padding(.vertical, 4)
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $bottomVisibleMessageID, anchor: .bottom)
            .onChange(of: bottomVisibleMessageID) { _, newValue in
                pinnedToBottom = newValue == nil || newValue == lastMessageID
            }
            .onChange(of: visibleMessages.count) {
                if pinnedToBottom {
                    bottomVisibleMessageID = lastMessageID
                }
            }
            .onChange(of: viewModel.activeConversationID) {
                pinnedToBottom = true
                bottomVisibleMessageID = lastMessageID
            }
            .onChange(of: viewModel.isStreaming) { _, newValue in
                if !newValue, pinnedToBottom {
                    bottomVisibleMessageID = lastMessageID
                }
            }

            if isUserScrolledUp {
                Button {
                    pinnedToBottom = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        bottomVisibleMessageID = lastMessageID
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isUserScrolledUp)
                .accessibilityLabel(String(localized: "Scroll to latest message"))
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss error"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .systemYellow).opacity(Self.warningBackgroundOpacity))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                AIChatContextChipStrip(
                    items: viewModel.attachedContext,
                    onRemove: { viewModel.detach($0) }
                )

                ChatComposerView(
                    text: $viewModel.inputText,
                    placeholder: String(localized: "Ask about your database..."),
                    minLines: 1,
                    maxLines: 5,
                    mentionState: mentionState,
                    onTextChange: { text, caret in
                        updateMentionState(text: text, caret: caret)
                    },
                    onSubmit: {
                        updateContext()
                        viewModel.sendMessage()
                    },
                    onAttach: { item in
                        viewModel.attach(item)
                    }
                )

                HStack(alignment: .center, spacing: 8) {
                    mentionMenu
                    slashCommandMenu
                    modeMenu
                    modelPicker
                    Spacer()
                    sendOrStopButton
                }
            }
            .padding(8)
        }
    }

    private var modeMenu: some View {
        let binding = Binding<AIChatMode>(
            get: { settingsManager.ai.chatMode },
            set: { newValue in
                var settings = settingsManager.ai
                settings.chatMode = newValue
                settingsManager.ai = settings
            }
        )
        return Menu {
            Picker("", selection: binding) {
                ForEach(AIChatMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName)
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: settingsManager.ai.chatMode.symbolName)
                Text(settingsManager.ai.chatMode.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(settingsManager.ai.chatMode.helpText)
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if viewModel.isStreaming {
            Button {
                viewModel.cancelStream()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Stop Generating"))
            .accessibilityLabel(String(localized: "Stop Generating"))
        } else {
            let isEmpty = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                updateContext()
                viewModel.sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(isEmpty ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .help(String(localized: "Send Message"))
            .accessibilityLabel(String(localized: "Send Message"))
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let providers = settingsManager.ai.providers
        if providers.isEmpty {
            EmptyView()
        } else {
            let activeProvider = settingsManager.ai.activeProvider
            let selectedProviderId = viewModel.selectedProviderId ?? activeProvider?.id
            let selectedProvider = providers.first(where: { $0.id == selectedProviderId }) ?? activeProvider
            let resolvedModel = viewModel.selectedModel ?? selectedProvider?.model ?? ""
            let label = selectedProvider.map { provider in
                resolvedModel.isEmpty ? provider.displayName : resolvedModel
            } ?? String(localized: "Select Model")

            Menu {
                ForEach(providers) { provider in
                    modelMenuSection(
                        provider: provider,
                        selectedProviderId: selectedProviderId,
                        selectedModel: resolvedModel
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Choose AI provider and model"))
        }
    }

    @ViewBuilder
    private var mentionMenu: some View {
        if let connectionId = viewModel.connection?.id {
            Menu {
                Button {
                    viewModel.attach(.schema(connectionId: connectionId))
                } label: {
                    Label(String(localized: "Schema"), systemImage: "tablecells")
                }
                .disabled(viewModel.tables.isEmpty)

                Menu(String(localized: "Tables")) {
                    let sortedTables = viewModel.tables.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    ForEach(sortedTables, id: \.name) { table in
                        Button {
                            viewModel.attach(.table(connectionId: connectionId, name: table.name))
                        } label: {
                            Text(table.name)
                        }
                    }
                }
                .disabled(viewModel.tables.isEmpty)

                Button {
                    if let query = currentQuery, !query.isEmpty {
                        viewModel.attach(.currentQuery(text: query))
                    }
                } label: {
                    Label(String(localized: "Current Query"), systemImage: "doc.text")
                }
                .disabled((currentQuery ?? "").isEmpty)

                Button {
                    if let results = queryResults, !results.isEmpty {
                        viewModel.attach(.queryResult(summary: results))
                    }
                } label: {
                    Label(String(localized: "Query Results"), systemImage: "list.bullet.rectangle")
                }
                .disabled((queryResults ?? "").isEmpty)
            } label: {
                Image(systemName: "at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Attach context"))
            .accessibilityLabel(String(localized: "Attach context"))
        }
    }

    private var slashCommandMenu: some View {
        let customCommands = CustomSlashCommandStorage.shared.commands.filter(\.isValid)
        return Menu {
            ForEach(SlashCommand.allCommands) { command in
                Button {
                    updateContext()
                    viewModel.runSlashCommand(command)
                } label: {
                    Text("/\(command.name) · \(command.description)")
                }
            }
            if !customCommands.isEmpty {
                Divider()
                Section(String(localized: "Custom")) {
                    ForEach(customCommands) { command in
                        Button {
                            updateContext()
                            Task { await viewModel.runCustomSlashCommand(command) }
                        } label: {
                            if command.description.isEmpty {
                                Text("/\(command.name)")
                            } else {
                                Text("/\(command.name) · \(command.description)")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "command")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Slash commands"))
        .accessibilityLabel(String(localized: "Slash commands"))
    }

    @ViewBuilder
    private func modelMenuSection(
        provider: AIProviderConfig,
        selectedProviderId: UUID?,
        selectedModel: String
    ) -> some View {
        let fallback = provider.model.isEmpty ? [] : [provider.model]
        let cached = viewModel.availableModels[provider.id] ?? []
        let models = cached.isEmpty ? fallback : cached

        if models.count > 1 {
            Section(provider.displayName) {
                ForEach(models, id: \.self) { model in
                    modelButton(
                        provider: provider,
                        model: model,
                        isSelected: provider.id == selectedProviderId && model == selectedModel
                    )
                }
            }
        } else if let single = models.first {
            modelButton(
                provider: provider,
                model: single,
                isSelected: provider.id == selectedProviderId && single == selectedModel,
                showProviderPrefix: true
            )
        }
    }

    private func modelButton(
        provider: AIProviderConfig,
        model: String,
        isSelected: Bool,
        showProviderPrefix: Bool = false
    ) -> some View {
        Button {
            viewModel.selectedProviderId = provider.id
            viewModel.selectedModel = model
        } label: {
            HStack {
                Text(showProviderPrefix ? "\(provider.displayName) · \(model)" : model)
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    // MARK: - Helpers

    private func updateContext() {
        viewModel.currentQuery = currentQuery
        viewModel.queryResults = queryResults
    }

    /// Hide system turns and user turns that exist only to carry tool-result
    /// blocks back to the model — those are protocol plumbing, not user input.
    private func isVisibleInMessageList(_ message: ChatTurn) -> Bool {
        guard message.role != .system else { return false }
        if message.role == .user {
            let hasUserContent = message.blocks.contains { block in
                switch block.kind {
                case .text(let value): return !value.isEmpty
                case .attachment: return true
                case .toolUse, .toolResult: return false
                }
            }
            if !hasUserContent { return false }
        }
        return true
    }

    private func updateMentionState(text: String, caret: Int) {
        guard let match = MentionDetector.detect(in: text, caret: caret) else {
            mentionState.reset()
            return
        }
        let candidates = mentionCandidates(forQuery: match.query)
        guard !candidates.isEmpty else {
            mentionState.reset()
            return
        }
        let queryChanged = match.query != mentionState.query
        mentionState.candidates = candidates
        mentionState.query = match.query
        mentionState.anchorRange = match.range
        if queryChanged {
            mentionState.selectedIndex = 0
        } else {
            mentionState.clampSelection()
        }
        mentionState.isVisible = true
    }

    private func mentionCandidates(forQuery query: String) -> [MentionCandidate] {
        let connectionId = connection.id
        var items: [MentionCandidate] = []

        let schemaItem = ContextItem.schema(connectionId: connectionId)
        if matchesQuery(schemaItem.displayLabel, query) {
            items.append(MentionCandidate(item: schemaItem))
        }

        if let editorQuery = currentQuery, !editorQuery.isEmpty {
            let item = ContextItem.currentQuery(text: editorQuery)
            if matchesQuery(item.displayLabel, query) {
                items.append(MentionCandidate(item: item))
            }
        }

        if let results = queryResults, !results.isEmpty {
            let item = ContextItem.queryResult(summary: results)
            if matchesQuery(item.displayLabel, query) {
                items.append(MentionCandidate(item: item))
            }
        }

        let tableBudget = max(0, (Self.maxMentionCandidates / 2) - items.count)
        let matchingTables = viewModel.tables
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(tableBudget)
        for table in matchingTables {
            items.append(MentionCandidate(
                item: .table(connectionId: connectionId, name: table.name)
            ))
        }

        let savedBudget = max(0, Self.maxMentionCandidates - items.count)
        let matchingSavedQueries = viewModel.savedQueries
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(savedBudget)
        for favorite in matchingSavedQueries {
            items.append(MentionCandidate(
                item: .savedQuery(id: favorite.id, name: favorite.name)
            ))
        }

        return items
    }

    private static let maxMentionCandidates = 10

    private func matchesQuery(_ label: String, _ query: String) -> Bool {
        query.isEmpty || label.localizedCaseInsensitiveContains(query)
    }

    private func shouldShowRetry(for message: ChatTurn) -> Bool {
        message.role == .user
            && message.id == viewModel.messages.last?.id
            && viewModel.lastMessageFailed
            && viewModel.canRetryLastFailure
    }

    private func shouldShowRegenerate(for message: ChatTurn) -> Bool {
        message.role == .assistant
            && message.id == viewModel.messages.last?.id
            && !viewModel.isStreaming
            && !message.plainText.isEmpty
    }
}
