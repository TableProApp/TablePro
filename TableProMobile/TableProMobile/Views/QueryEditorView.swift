//
//  QueryEditorView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels

struct QueryEditorView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorView")

    @State private var query = ""
    @State private var result: QueryResult?
    @State private var appError: AppError?
    @State private var isExecuting = false
    @State private var executionTime: TimeInterval?
    @State private var executeTask: Task<Void, Never>?
    @State private var saveQueryTask: Task<Void, Never>?
    @State private var executionStartTime: Date?
    @State private var showWriteConfirmation = false
    @State private var showWriteBlockedAlert = false
    @State private var pendingWriteQuery = ""
    @State private var showClearConfirmation = false
    @State private var showShareSheet = false
    @State private var shareText = ""
    @State private var hapticSuccess = false
    @State private var hapticError = false

    private var session: ConnectionSession? { coordinator.session }
    private var tables: [TableInfo] { coordinator.tables }
    private var databaseType: DatabaseType { coordinator.connection.type }
    private var safeModeLevel: SafeModeLevel { coordinator.connection.safeModeLevel }
    private var connectionId: UUID { coordinator.connection.id }

    var body: some View {
        VStack(spacing: 0) {
            editorSection
            Divider()
            resultSection
        }
        .onAppear {
            if let pending = coordinator.pendingQuery {
                query = pending
                coordinator.pendingQuery = nil
            } else if query.isEmpty {
                query = UserDefaults.standard.string(forKey: "lastQuery.\(connectionId.uuidString)") ?? ""
            }
        }
        .onChange(of: query) { _, newValue in
            saveQueryTask?.cancel()
            saveQueryTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(newValue, forKey: "lastQuery.\(connectionId.uuidString)")
            }
        }
        .onDisappear {
            saveQueryTask?.cancel()
        }
        .onChange(of: coordinator.pendingQuery) { _, newQuery in
            if let newQuery {
                query = newQuery
                coordinator.pendingQuery = nil
            }
        }
        .alert(String(localized: "Write Query Blocked"), isPresented: $showWriteBlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This connection is in read-only mode. Write queries are not allowed.")
        }
        .confirmationDialog(String(localized: "Execute Write Query?"), isPresented: $showWriteConfirmation, titleVisibility: .visible) {
            Button(String(localized: "Execute"), role: .destructive) {
                executeTask = Task { await executeQueryDirect(pendingWriteQuery) }
            }
        } message: {
            Text("This query will modify data. Are you sure you want to continue?")
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(items: [shareText])
        }
        .confirmationDialog(
            String(localized: "Clear Query"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear"), role: .destructive) {
                query = ""
                result = nil
                appError = nil
                executionTime = nil
            }
        } message: {
            Text("Query text and results will be cleared.")
        }
    }

    // MARK: - Editor

    private var editorSection: some View {
        VStack(spacing: 0) {
            SQLHighlightTextView(text: $query)
                .frame(minHeight: 80, maxHeight: result != nil || appError != nil ? 120 : 250)

            actionBar
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                if isExecuting {
                    executeTask?.cancel()
                    Task { try? await session?.driver.cancelCurrentQuery() }
                } else {
                    executeTask = Task { await executeQuery() }
                }
            } label: {
                Label(
                    isExecuting ? String(localized: "Stop") : String(localized: "Run"),
                    systemImage: isExecuting ? "stop.fill" : "play.fill"
                )
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isExecuting ? .red : .accentColor)
            .disabled(!isExecuting && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)

            Spacer()

            if isExecuting, let startTime = executionStartTime {
                TimelineView(.periodic(from: startTime, by: 0.1)) { context in
                    let elapsed = context.date.timeIntervalSince(startTime)
                    Text(String(format: "%.1fs", elapsed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let time = executionTime {
                Text(String(format: "%.1fms", time * 1_000))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let result, !result.rows.isEmpty {
                Text(verbatim: "\(result.rows.count) rows")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            queryMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Results

    private var resultSection: some View {
        Group {
            if isExecuting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Executing...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let appError {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(verbatim: appError.message)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        if let recovery = appError.recovery {
                            Text(verbatim: recovery)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 28)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let result {
                if result.columns.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        Text(String(format: String(localized: "%d row(s) affected"), result.rowsAffected))
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if result.rows.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "tray")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    resultList(result)
                }
            } else {
                ContentUnavailableView {
                    Label("Run a Query", systemImage: "terminal")
                } description: {
                    Text("Write SQL and tap the play button.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func resultList(_ result: QueryResult) -> some View {
        List {
            ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
                NavigationLink {
                    RowDetailView(
                        columns: result.columns,
                        rows: result.rows,
                        initialIndex: rowIndex
                    )
                } label: {
                    resultRowCard(columns: result.columns, row: row)
                }
                .contextMenu {
                    resultRowContextMenu(columns: result.columns, row: row)
                }
            }
        }
        .listStyle(.plain)
    }

    private func resultRowCard(columns: [ColumnInfo], row: [String?]) -> some View {
        let preview = Array(zip(columns, row).prefix(4))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(preview.enumerated()), id: \.offset) { index, pair in
                HStack(spacing: 6) {
                    Text(pair.0.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: pair.1 ?? "NULL")
                        .font(index == 0 ? .subheadline : .caption)
                        .fontWeight(index == 0 ? .medium : .regular)
                        .foregroundStyle(pair.1 == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
            if columns.count > 4 {
                Text("+\(columns.count - 4) more columns")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resultRowContextMenu(columns: [ColumnInfo], row: [String?]) -> some View {
        if let firstValue = row.first, let value = firstValue {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy Value", systemImage: "doc.on.doc")
            }
        }
        Menu("Copy Row") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.rawValue) {
                    let text = ClipboardExporter.exportRow(
                        columns: columns, row: row,
                        format: format
                    )
                    ClipboardExporter.copyToClipboard(text)
                }
            }
        }
    }

    // MARK: - Query Menu

    private var queryMenu: some View {
        Menu {
            Button {
                coordinator.selectedTab = .history
            } label: {
                Label("History", systemImage: "clock")
            }

            if !tables.isEmpty {
                Menu {
                    ForEach(tables) { table in
                        Button(table.name) {
                            let quoted = SQLBuilder.quoteIdentifier(table.name, for: databaseType)
                            query = "SELECT * FROM \(quoted) LIMIT 100"
                        }
                    }
                } label: {
                    Label("SELECT * FROM ...", systemImage: "text.badge.star")
                }
            }

            if let result, !result.rows.isEmpty {
                Section("Share Results") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            shareText = ClipboardExporter.exportRows(
                                columns: result.columns, rows: result.rows,
                                format: format
                            )
                            showShareSheet = true
                        } label: {
                            Label(format.rawValue, systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Section("Copy Results") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            let text = ClipboardExporter.exportRows(
                                columns: result.columns, rows: result.rows,
                                format: format
                            )
                            ClipboardExporter.copyToClipboard(text)
                        } label: {
                            Label(format.rawValue, systemImage: "doc.on.clipboard")
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Execution

    private func isWriteQuery(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let writeKeywords = ["INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE", "TRUNCATE", "REPLACE"]
        return writeKeywords.contains(where: { trimmed.hasPrefix($0) })
    }

    private func executeQuery() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isWriteQuery(trimmed) {
            if safeModeLevel.blocksWrites {
                showWriteBlockedAlert = true
                return
            }
            if safeModeLevel.requiresConfirmation {
                pendingWriteQuery = trimmed
                showWriteConfirmation = true
                return
            }
        }

        await executeQueryDirect(trimmed)
    }

    private func executeQueryDirect(_ trimmed: String) async {
        guard let session else { return }

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isExecuting = true
        executionStartTime = Date()
        defer {
            isExecuting = false
            executionStartTime = nil
        }
        appError = nil
        result = nil

        do {
            let queryResult = try await session.driver.execute(query: trimmed)
            self.result = queryResult
            self.executionTime = queryResult.executionTime
            hapticSuccess.toggle()

            IOSAnalyticsProvider.shared.markFirstQueryExecuted()

            let item = QueryHistoryItem(query: trimmed, connectionId: connectionId)
            coordinator.addHistoryItem(item)
        } catch {
            let context = ErrorContext(operation: "executeQuery")
            self.appError = ErrorClassifier.classify(error, context: context)
            hapticError.toggle()
        }
    }
}
