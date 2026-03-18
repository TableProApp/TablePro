//
//  AIChatPanelView.swift
//  TablePro
//
//  AI chat panel view - right-side panel for conversing with AI about database queries.
//

import OSLog
import SwiftUI

/// AI chat panel displayed alongside the main editor content
struct AIChatPanelView: View {
    let connection: DatabaseConnection
    let tables: [TableInfo]
    var currentQuery: String?
    var queryResults: String?

    @Bindable var viewModel: AIChatViewModel
    private let settingsManager = AppSettingsManager.shared
    @State private var isNearBottom: Bool = true

    private var hasConfiguredProvider: Bool {
        settingsManager.ai.providers.contains(where: { $0.isEnabled })
    }

    var body: some View {
        VStack(spacing: 0) {
            header

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
            viewModel.tables = tables
        }
        .onChange(of: tables) { _, newTables in
            viewModel.tables = newTables
        }
        .task(id: tables) {
            await fetchSchemaContext()
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            // Left: New conversation button
            Button {
                viewModel.startNewConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(String(localized: "New Conversation"))

            Spacer()

            // Center: Conversation title as dropdown
            Menu {
                if !viewModel.conversations.isEmpty {
                    Section(String(localized: "Recent Conversations")) {
                        ForEach(viewModel.conversations) { conversation in
                            Button {
                                viewModel.switchConversation(to: conversation.id)
                            } label: {
                                HStack {
                                    Text(conversation.title.isEmpty
                                        ? String(localized: "Untitled")
                                        : conversation.title)
                                    if conversation.id == viewModel.activeConversationID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button(role: .destructive) {
                    viewModel.clearConversation()
                } label: {
                    Label(String(localized: "Clear Recents"), systemImage: "trash")
                }
                .disabled(viewModel.conversations.isEmpty)
            } label: {
                HStack(spacing: 4) {
                    let title = viewModel.conversations
                        .first(where: { $0.id == viewModel.activeConversationID })?.title
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Text(title.isEmpty ? String(localized: "New Chat") : title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // Right: Spacer to balance layout (history menu removed)
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Ask AI about your database"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "Get help writing queries, explaining schemas, or fixing errors."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Provider State

    private var noProviderState: some View {
        ContentUnavailableView {
            Label(String(localized: "Set Up AI Provider"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "Configure an AI provider in Settings to start chatting."))
        } actions: {
            SettingsLink {
                Text(String(localized: "Go to Settings…"))
            }
            .simultaneousGesture(TapGesture().onEnded {
                UserDefaults.standard.set(SettingsTab.ai.rawValue, forKey: "selectedSettingsTab")
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        if message.role != .system {
                            // Extra spacing before user messages to separate conversation turns
                            if message.role == .user
                                && index > 0
                                && viewModel.messages[0..<index].contains(where: { $0.role == .assistant })
                            {
                                Spacer()
                                    .frame(height: 16)
                            }
                            AIChatMessageView(
                                message: message,
                                onRetry: shouldShowRetry(for: message) ? { viewModel.retry() } : nil,
                                onRegenerate: shouldShowRegenerate(for: message) ? { viewModel.regenerate() } : nil
                            )
                            .padding(.vertical, 4)
                            .id(message.id)
                        }
                    }

                    // Invisible bottom anchor to track scroll position
                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                        .onAppear { isNearBottom = true }
                        .onDisappear { isNearBottom = false }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if !viewModel.messages.isEmpty {
                    // Delay to let ScrollView finish layout before scrolling
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottomAnchor", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.messages.last?.content) {
                if isNearBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottomAnchor", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.messages.count) {
                // Always scroll on new message (user just sent a message)
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.activeConversationID) {
                // Scroll to bottom when switching conversations
                DispatchQueue.main.async {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.1))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                TextField(
                    String(localized: "Ask about your database..."),
                    text: $viewModel.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        updateContext()
                        viewModel.sendMessage()
                    }
                }

                if viewModel.isStreaming {
                    Button {
                        viewModel.cancelStream()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Stop Generating"))
                } else {
                    Button {
                        updateContext()
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(
                                viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? .secondary : Color.accentColor
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(String(localized: "Send Message"))
                }
            }
            .padding(8)
        }
    }

    // MARK: - Schema Context

    private static let logger = Logger(subsystem: "com.TablePro", category: "AIChatPanelView")

    /// Fetch column and foreign key info for tables and populate the view model.
    /// Reuses cached columns from the shared `SQLSchemaProvider` when available,
    /// falling back to direct driver queries only for uncached data.
    /// Respects AI settings (`includeSchema`, `maxSchemaTables`).
    private func fetchSchemaContext() async {
        let settings = AppSettingsManager.shared.ai
        guard settings.includeSchema,
              let driver = DatabaseManager.shared.driver(for: connection.id)
        else { return }

        let tablesToFetch = Array(tables.prefix(settings.maxSchemaTables))
        var columns: [String: [ColumnInfo]] = [:]
        var foreignKeys: [String: [ForeignKeyInfo]] = [:]

        let provider = viewModel.schemaProvider

        for table in tablesToFetch {
            if let provider {
                let cached = await provider.getColumns(for: table.name)
                if !cached.isEmpty {
                    columns[table.name] = cached
                }
            }

            if columns[table.name] == nil {
                do {
                    let cols = try await driver.fetchColumns(table: table.name)
                    columns[table.name] = cols
                } catch {
                    Self.logger.warning(
                        "Failed to fetch columns for table '\(table.name)': \(error.localizedDescription)"
                    )
                }
            }
        }

        // Fetch foreign keys for the needed tables in bulk
        do {
            let fkResult = try await driver.fetchForeignKeys(forTables: tablesToFetch.map(\.name))
            for (table, fks) in fkResult {
                foreignKeys[table] = fks
            }
        } catch {
            Self.logger.warning("Failed to bulk fetch foreign keys: \(error.localizedDescription)")
        }

        viewModel.columnsByTable = columns
        viewModel.foreignKeysByTable = foreignKeys
    }

    // MARK: - Helpers

    private func updateContext() {
        viewModel.currentQuery = currentQuery
        viewModel.queryResults = queryResults
    }

    private func shouldShowRetry(for message: AIChatMessage) -> Bool {
        message.role == .user
            && message.id == viewModel.messages.last?.id
            && viewModel.lastMessageFailed
    }

    private func shouldShowRegenerate(for message: AIChatMessage) -> Bool {
        message.role == .assistant
            && message.id == viewModel.messages.last?.id
            && !viewModel.isStreaming
            && !message.content.isEmpty
    }
}
