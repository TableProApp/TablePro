import os
import SwiftUI
import TableProDatabase
import TableProModels
import TableProQuery

struct QueryEditorView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorView")

    @State private var query = ""
    @State private var editorFocused = false
    @State private var viewModel = QueryEditorViewModel()
    @State private var appError: AppError?
    @State private var isExecuting = false
    @State private var executionTime: TimeInterval?
    @State private var executeTask: Task<Void, Never>?

    private var hasResult: Bool {
        !viewModel.columns.isEmpty || viewModel.rowsAffected != nil
    }

    private var resultRowCount: Int {
        viewModel.legacyRows.count
    }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await viewModel.handlePressure(.warning) }
        }
        .onChange(of: MemoryPressureMonitor.shared.currentLevel) { _, level in
            Task { await viewModel.handlePressure(level) }
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
                viewModel.reset()
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
            SQLHighlightTextView(text: $query, isFocused: $editorFocused)
                .frame(minHeight: 80, maxHeight: hasResult || appError != nil ? 120 : 250)

            actionBar
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                if isExecuting {
                    executeTask?.cancel()
                    viewModel.stop()
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

            if resultRowCount > 0 {
                Text("\(resultRowCount) rows")
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
            } else if hasResult {
                if viewModel.columns.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        Text(String(format: String(localized: "%d row(s) affected"), viewModel.rowsAffected ?? 0))
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.legacyRows.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "tray",
                        description: Text("The query returned no rows.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        if let message = viewModel.truncationMessage {
                            truncationBanner(message)
                            Divider()
                        }
                        resultList
                    }
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

    private func truncationBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private var resultList: some View {
        let indexed = IndexedRow.wrap(viewModel.legacyRows)
        return List {
            ForEach(indexed) { item in
                let rowIndex = item.id
                let row = item.values
                NavigationLink {
                    RowDetailView(
                        columns: viewModel.columns,
                        rows: viewModel.window.rows,
                        initialIndex: rowIndex
                    )
                } label: {
                    resultRowCard(columns: viewModel.columns, row: row)
                }
                .contextMenu {
                    resultRowContextMenu(columns: viewModel.columns, row: row)
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
                ClipboardExporter.copyToClipboard(value)
            } label: {
                Label("Copy Value", systemImage: "doc.on.doc")
            }
        }
        Menu("Copy Row") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.rawValue) {
                    let text = ClipboardExporter.exportRow(
                        columns: columns, row: row,
                        format: format,
                        databaseType: databaseType, driver: coordinator.session?.driver
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

            if !viewModel.legacyRows.isEmpty {
                Section("Share Results") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            shareText = ClipboardExporter.exportRows(
                                columns: viewModel.columns, rows: viewModel.legacyRows,
                                format: format,
                                databaseType: databaseType, driver: coordinator.session?.driver
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
                                columns: viewModel.columns, rows: viewModel.legacyRows,
                                format: format,
                                databaseType: databaseType, driver: coordinator.session?.driver
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

    private func executeQuery() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if SQLWriteClassifier.isWriteQuery(trimmed, databaseType: databaseType) {
            switch safeModeLevel.writePermission {
            case .blocked:
                showWriteBlockedAlert = true
                return
            case .requiresConfirmation:
                pendingWriteQuery = trimmed
                showWriteConfirmation = true
                return
            case .proceed:
                break
            }
        }

        await executeQueryDirect(trimmed)
    }

    private func executeQueryDirect(_ trimmed: String) async {
        guard let session else { return }

        editorFocused = false
        isExecuting = true
        let startedAt = Date()
        executionStartTime = startedAt
        appError = nil

        let token = await appState.queryActivities.start(
            connectionId: connectionId,
            connectionName: coordinator.displayName,
            query: trimmed,
            startedAt: startedAt
        )

        guard !Task.isCancelled else {
            isExecuting = false
            executionStartTime = nil
            await appState.queryActivities.end(token: token, outcome: .stopped)
            recordHistory(query: trimmed, outcome: .stopped, errorMessage: QueryExecutionOutcome.stopped.historyMessage)
            return
        }

        let progressUpdater = startActivityProgressUpdater(token: token)

        await viewModel.run(driver: session.driver, query: trimmed)

        progressUpdater.cancel()
        let phase = viewModel.phase
        let outcome = QueryExecutionOutcome(phase: phase)
        let elapsed = viewModel.executionTime
        isExecuting = false
        executionStartTime = nil

        await appState.queryActivities.end(token: token, outcome: outcome.activityOutcome)

        if case .error(let err) = phase {
            appError = err
            hapticError.toggle()
            recordHistory(query: trimmed, outcome: outcome, errorMessage: err.localizedDescription)
            return
        }

        executionTime = elapsed

        guard outcome == .completed else {
            recordHistory(query: trimmed, outcome: outcome, errorMessage: outcome.historyMessage)
            return
        }

        hapticSuccess.toggle()

        IOSAnalyticsProvider.shared.markFirstQueryExecuted()

        recordHistory(query: trimmed, outcome: outcome, errorMessage: nil)
    }

    private func recordHistory(query: String, outcome: QueryExecutionOutcome, errorMessage: String?) {
        coordinator.addHistoryItem(
            QueryHistoryItem(
                query: query,
                connectionId: connectionId,
                wasSuccessful: outcome == .completed,
                errorMessage: errorMessage
            )
        )
    }

    // MARK: - Live Activity

    private func startActivityProgressUpdater(token: QueryExecutionToken?) -> Task<Void, Never> {
        let controller = appState.queryActivities
        return Task { [weak viewModel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let count = viewModel?.legacyRows.count else { return }
                await controller.update(token: token, rowsStreamed: count)
            }
        }
    }
}
