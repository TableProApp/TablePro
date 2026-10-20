import os
import SwiftUI
import TableProDatabase
import TableProModels
import TableProQuery

struct QueryEditorView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorView")

    @State private var query = ""
    @State private var editorFocused = false
    @State private var editorHandle = SQLEditorHandle()
    @State private var viewModel = QueryEditorViewModel()
    @State private var completion = QueryCompletionController()
    @State private var appError: AppError?
    @State private var isExecuting = false
    @State private var executionTime: TimeInterval?
    @State private var executeTask: Task<Void, Never>?

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
    @State private var resultsExportError: ClipboardExporter.IncompleteValues?
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var containerSize: CGSize = .zero
    @State private var savedQueriesRoute: SavedQueriesSheetRoute?
    @State private var savedQueryFolderExpansion: Set<UUID> = []

    private var session: ConnectionSession? { coordinator.session }
    private var tables: [TableInfo] { coordinator.tables }
    private var databaseType: DatabaseType { coordinator.connection.type }
    private var activeSchema: String? { coordinator.supportsSchemas ? coordinator.activeSchema : nil }
    private var safeModeLevel: SafeModeLevel { coordinator.connection.safeModeLevel }
    private var connectionId: UUID { coordinator.connection.id }

    private var completionScope: QueryCompletionScope {
        QueryCompletionScope(
            connectionId: connectionId,
            sessionID: session.map { ObjectIdentifier($0.driver) },
            database: coordinator.activeDatabase,
            schema: activeSchema ?? "",
            databaseType: databaseType,
            tables: tables,
            isRunning: isExecuting
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            editorSection
            Divider()
            resultSection
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .onAppear {
            editorHandle.databaseType = databaseType
            if let pending = coordinator.pendingQuery {
                query = pending
                coordinator.pendingQuery = nil
            } else if query.isEmpty {
                query = UserDefaults.standard.string(forKey: ConnectionDefaultsKey.lastQuery.name(for: connectionId)) ?? ""
            }
        }
        .task(id: session.map { ObjectIdentifier($0.driver) }) {
            editorHandle.sessionFacts = await session?.driver.sessionLexicalFacts()
        }
        .onChange(of: query) { _, newValue in
            saveQueryTask?.cancel()
            saveQueryTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(newValue, forKey: ConnectionDefaultsKey.lastQuery.name(for: connectionId))
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
        .onChange(of: completionScope, initial: true) { _, scope in
            completion.update(scope: scope, readColumns: QueryCompletionController.columnReader { coordinator.session })
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
        .sheet(item: $savedQueriesRoute) { route in
            SavedQueriesSheet(
                route: route,
                connectionId: connectionId,
                expandedFolderIds: $savedQueryFolderExpansion
            ) { coordinator.pendingQuery = SavedQueryDraft.editorText(opening: $0) }
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

    private var duoWidthClass: DuoWidthClass {
        horizontalSizeClass == .regular ? .regular : .compact
    }

    private var editorMaxHeight: CGFloat {
        DuoLayoutResolver.editorMaxHeight(
            for: DuoLayoutContext(
                size: containerSize,
                widthClass: duoWidthClass,
                showsResult: viewModel.hasOutcome || appError != nil
            )
        )
    }

    private var editorSection: some View {
        VStack(spacing: 0) {
            SQLHighlightTextView(text: $query, isFocused: $editorFocused, handle: editorHandle, completion: completion)
                .frame(minHeight: 80, maxHeight: editorMaxHeight)

            actionBar
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if isExecuting {
                Button {
                    executeTask?.cancel()
                    viewModel.stop()
                    Task { try? await session?.driver.cancelCurrentQuery() }
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Menu {
                    Button {
                        runAtCursor(dismissingKeyboard: true)
                    } label: {
                        Label(runAtCursorTitle, systemImage: "play")
                    }
                    Button {
                        runAllStatements(dismissingKeyboard: true)
                    } label: {
                        Label("Run All Statements", systemImage: "play.square.stack")
                    }
                } label: {
                    Label(String(localized: "Run"), systemImage: "play.fill")
                        .font(.subheadline.weight(.medium))
                } primaryAction: {
                    runAtCursor(dismissingKeyboard: true)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRun)
                .accessibilityHint(Text("Runs the statement at the cursor, or the selected text."))
            }

            Spacer()

            if let runNote = editorHandle.runNote {
                Text(verbatim: runNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isExecuting, let startTime = executionStartTime {
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

            if resultRowCount > 0, editorHandle.runNote == nil {
                Text("\(resultRowCount) rows")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            queryMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Button(runAtCursorTitle) { runAtCursor(dismissingKeyboard: false) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canRun)
                .hidden()
            Button("Run All Statements") { runAllStatements(dismissingKeyboard: false) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!canRun)
                .hidden()
        }
    }

    private var canRun: Bool {
        !isExecuting && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var runAtCursorTitle: String {
        editorHandle.hasSelection ? String(localized: "Run Selection") : String(localized: "Run Statement")
    }

    // MARK: - Results

    private var resultSection: some View {
        Group {
            if isExecuting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(verbatim: viewModel.progressMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let appError {
                errorView(appError)
            } else if !viewModel.hasOutcome {
                ContentUnavailableView {
                    Label("Run a Query", systemImage: "terminal")
                } description: {
                    Text("Write SQL and tap the play button.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.columns.isEmpty || viewModel.legacyRows.isEmpty && !runCompleted {
                commandOutcomeView
            } else if viewModel.legacyRows.isEmpty {
                VStack(spacing: 0) {
                    resultNotices(includesTruncation: false)
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "tray",
                        description: Text("The query returned no rows.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    resultNotices(includesTruncation: true)
                    resultList
                }
            }
        }
    }

    private func errorView(_ appError: AppError) -> some View {
        let isScriptFailure = isScriptFailure
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(verbatim: isScriptFailure ? viewModel.interruptionHeadline ?? appError.message : appError.message)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.red)
                }
                if isScriptFailure, let note = viewModel.standingWorkNote {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                }
                if isScriptFailure, let sql = viewModel.failedSQL {
                    Text(verbatim: sql)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(.leading, 28)
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
    }

    /// The error on screen is the run's own only while the view model still holds the failure that produced it.
    private var isScriptFailure: Bool {
        guard case .error = viewModel.phase else { return false }
        return viewModel.interruption != nil
    }

    private var runCompleted: Bool {
        QueryExecutionOutcome(phase: viewModel.phase) == .completed
    }

    /// A statement that returns no rows still ran, so it gets an outcome of its own rather than the empty placeholder.
    private var commandOutcomeView: some View {
        let outcome = QueryExecutionOutcome(phase: viewModel.phase)
        let completed = outcome == .completed
        return VStack(spacing: 8) {
            Image(systemName: completed ? "checkmark.circle.fill" : "stop.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(completed ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: completed
                ? viewModel.commandMessage
                : viewModel.interruptionHeadline ?? outcome.historyMessage ?? viewModel.commandMessage)
                .font(.body)
                .multilineTextAlignment(.center)
            if let detail = completed ? viewModel.scriptSummary : viewModel.standingWorkNote {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultNotices(includesTruncation: Bool) -> some View {
        if let headline = viewModel.interruptionHeadline {
            noticeBanner(
                [headline, viewModel.standingWorkNote].compactMap { $0 }.joined(separator: " "),
                systemImage: "stop.circle.fill",
                tint: .secondary
            )
            Divider()
        } else if includesTruncation, let message = viewModel.truncationMessage {
            noticeBanner(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            Divider()
        }
        if let summary = viewModel.scriptSummary {
            noticeBanner(summary, systemImage: "checkmark.circle.fill", tint: .green)
            Divider()
        }
    }

    private func noticeBanner(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
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
                    resultRowContextMenu(columns: viewModel.columns, rowIndex: rowIndex)
                }
            }
        }
        .listStyle(.plain)
    }

    private func resultRowCard(columns: [ColumnInfo], row: [String?]) -> some View {
        let budget = DuoLayoutResolver.previewFieldCount(for: duoWidthClass)
        let preview = Array(zip(columns, row).prefix(budget))
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
            if columns.count > budget {
                Text("+\(columns.count - budget) more columns")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resultRowContextMenu(columns: [ColumnInfo], rowIndex: Int) -> some View {
        let rows = viewModel.window.rows
        let cells = rows.indices.contains(rowIndex) ? rows[rowIndex].cells : []
        if case .text(let value)? = cells.first {
            Button {
                ClipboardExporter.copyToClipboard(value)
            } label: {
                Label("Copy Value", systemImage: "doc.on.doc")
            }
        }
        if ClipboardExporter.incompleteColumns(columns: columns, cells: cells).isEmpty {
            Menu("Copy Row") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.rawValue) {
                        guard let text = try? ClipboardExporter.exportRow(
                            columns: columns, cells: cells,
                            format: format,
                            databaseType: databaseType, driver: coordinator.session?.driver
                        ) else { return }
                        ClipboardExporter.copyToClipboard(text)
                    }
                }
            }
        }
    }

    // MARK: - Query Menu

    private var queryMenu: some View {
        Menu {
            Button {
                savedQueriesRoute = .list
            } label: {
                Label("Saved Queries", systemImage: "list.star")
            }

            Button {
                savedQueriesRoute = SavedQueryDraft.savableSQL(from: query).map { SavedQueriesSheetRoute.save(sql: $0) }
            } label: {
                Label("Save Query…", systemImage: "star")
            }
            .disabled(!query.contains { !$0.isWhitespace } || appState.savedQueries.status != .ready)

            Divider()

            Button {
                coordinator.selectedTab = .history
            } label: {
                Label("History", systemImage: "clock")
            }

            Button {
                runAllStatements(dismissingKeyboard: true)
            } label: {
                Label("Run All Statements", systemImage: "play.square.stack")
            }
            .disabled(!canRun)

            if !tables.isEmpty, databaseType.speaksSQL {
                Menu {
                    ForEach(tables) { table in
                        if let template = QueryTemplate.selectAll(
                            table: table.name, schema: activeSchema, type: databaseType
                        ) {
                            Button(table.name) {
                                query = template
                            }
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
                            do throws(ClipboardExporter.IncompleteValues) {
                                shareText = try ClipboardExporter.exportRows(
                                    columns: viewModel.columns, rows: viewModel.window.rows.map(\.cells),
                                    format: format,
                                    databaseType: databaseType, driver: coordinator.session?.driver
                                )
                                showShareSheet = true
                            } catch {
                                resultsExportError = error
                            }
                        } label: {
                            Label(format.rawValue, systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Section("Copy Results") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            do throws(ClipboardExporter.IncompleteValues) {
                                let text = try ClipboardExporter.exportRows(
                                    columns: viewModel.columns, rows: viewModel.window.rows.map(\.cells),
                                    format: format,
                                    databaseType: databaseType, driver: coordinator.session?.driver
                                )
                                ClipboardExporter.copyToClipboard(text)
                            } catch {
                                resultsExportError = error
                            }
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
        .alert(
            String(localized: "Cannot Export"),
            isPresented: Binding(
                get: { resultsExportError != nil },
                set: { if !$0 { resultsExportError = nil } }
            ),
            presenting: resultsExportError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(verbatim: error.localizedDescription)
        }
    }

    // MARK: - Execution

    private func runAtCursor(dismissingKeyboard: Bool) {
        let target = editorHandle.runTarget()
        if dismissingKeyboard { editorHandle.endEditing() }
        switch target {
        case .selection(let text), .statement(let text, _):
            executeTask = Task { await executeQuery(text) }
        case .nothing:
            editorHandle.noteNothingToRun()
            hapticError.toggle()
        }
    }

    private func runAllStatements(dismissingKeyboard: Bool) {
        if dismissingKeyboard { editorHandle.endEditing() }
        executeTask = Task { await executeQuery(query) }
    }

    private func executeQuery(_ text: String) async {
        guard !isExecuting else { return }
        let trimmed = QueryScript.trimmed(text, databaseType: databaseType)
        guard !trimmed.isEmpty else { return }
        guard let session else { return }
        // Text that is only comments plans to nothing under any session setting, so this needs no driver round trip.
        let outline = QueryScript.plan(
            trimmed, databaseType: databaseType, sendsBatchesWhole: session.driver.sendsBatchesWhole
        )
        guard !outline.isEmpty else {
            reportNothingToRun()
            return
        }

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

    // Claimed before the first await, so a second Run while the session reports how it reads literals starts nothing.
    private func executeQueryDirect(_ trimmed: String) async {
        guard let session, !isExecuting else { return }

        isExecuting = true
        let startedAt = Date()
        executionStartTime = startedAt
        appError = nil
        editorHandle.clearRunNote()

        await completion.finishColumnReads()
        let script = await plan(trimmed, on: session)
        guard !script.isEmpty else {
            isExecuting = false
            executionStartTime = nil
            reportNothingToRun()
            return
        }

        let token = await appState.queryActivities.start(
            connectionId: connectionId,
            connectionName: coordinator.displayName,
            query: trimmed,
            startedAt: startedAt
        )

        guard !Task.isCancelled else {
            recordHistory(query: trimmed, outcome: .stopped, errorMessage: QueryExecutionOutcome.stopped.historyMessage)
            isExecuting = false
            executionStartTime = nil
            await appState.queryActivities.end(token: token, outcome: .stopped)
            return
        }

        let progressUpdater = startActivityProgressUpdater(token: token)

        await coordinator.track(failed: { _ in QueryExecutionOutcome(phase: viewModel.phase) == .failed }) {
            await viewModel.run(driver: session.driver, script: script)
        }

        progressUpdater.cancel()
        let phase = viewModel.phase
        let outcome = QueryExecutionOutcome(phase: phase)

        // A stopped request may still hold the driver, and reading the session would wait for the statement Stop ends.
        if outcome == .completed || outcome == .failed, coordinator.session?.driver === session.driver {
            editorHandle.sessionFacts = await session.driver.sessionLexicalFacts()
        }

        if case .error(let err) = phase {
            appError = err
            hapticError.toggle()
            recordHistory(
                query: trimmed,
                outcome: outcome,
                errorMessage: viewModel.interruptionSummary ?? err.localizedDescription
            )
        } else {
            executionTime = viewModel.executionTime
            if outcome == .completed {
                hapticSuccess.toggle()
                IOSAnalyticsProvider.shared.markFirstQueryExecuted()
            }
            recordHistory(
                query: trimmed,
                outcome: outcome,
                errorMessage: viewModel.interruptionSummary ?? outcome.historyMessage
            )
        }

        isExecuting = false
        executionStartTime = nil

        await appState.queryActivities.end(token: token, outcome: outcome.activityOutcome)
    }

    private func plan(_ text: String, on session: ConnectionSession) async -> QueryScript {
        QueryScript.plan(
            text,
            databaseType: databaseType,
            sendsBatchesWhole: session.driver.sendsBatchesWhole,
            session: await session.driver.sessionLexicalFacts()
        )
    }

    /// Text that holds only comments reaches no driver, so the tap still gets an answer.
    private func reportNothingToRun() {
        viewModel.reset()
        executionTime = nil
        appError = AppError(
            category: .query,
            title: String(localized: "Nothing to Run"),
            message: String(localized: "There is no statement to run."),
            recovery: nil,
            underlying: nil
        )
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
