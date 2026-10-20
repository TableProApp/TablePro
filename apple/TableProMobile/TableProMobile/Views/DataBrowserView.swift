import SwiftUI
import TableProDatabase
import TableProModels
import TableProQuery

struct DataBrowserView: View {
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let table: TableInfo
    private let reference: ForeignKeyReference?

    init(table: TableInfo, reference: ForeignKeyReference? = nil) {
        self.table = table
        self.reference = reference
    }

    private var connection: DatabaseConnection { coordinator.connection }
    private var session: ConnectionSession? { coordinator.session }

    @State private var viewModel = DataBrowserViewModel()
    /// Not persisted. This search runs on the server and is applied on submit, so a value restored
    /// into the field would name a filter the rows on screen were never fetched under.
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showInsertSheet = false
    @State private var showFilterSheet = false
    @State private var showShareSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showStructure = false
    @State private var showMatchedRow = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var deleteTarget: RowLocator?
    @State private var fkPreviewItem: FKPreviewItem?
    @State private var shareText = ""
    @State private var isCompletingCells = false
    @State private var hapticSuccess = false
    @State private var hapticError = false

    private var activeSchema: String? {
        coordinator.supportsSchemas ? coordinator.activeSchema : nil
    }

    private var browserSchema: String? {
        if let reference { return reference.schema }
        return activeSchema
    }

    private var displaySchema: String? {
        reference?.displaySchema(current: activeSchema)
    }

    /// Asked of the kind rather than compared against the two view cases, so a MariaDB sequence,
    /// which refuses UPDATE and DELETE with ERROR 1031, is read-only here as it is on Mac.
    private var allowsRowEditing: Bool { table.type.allowsRowEditing }
    private var browseMode: TableBrowseMode { TableBrowseMode(driver: session?.driver) }
    private var browsesSQLRows: Bool { browseMode == .sql }

    /// Both entry points ask this. A key's contents take no `INSERT`, and the form cannot be filled
    /// in before the column list has arrived.
    private var canInsertRow: Bool {
        allowsRowEditing && browsesSQLRows
            && !connection.safeModeLevel.blocksWrites && !viewModel.columnDetails.isEmpty
    }

    private var canDeleteRows: Bool {
        allowsRowEditing && browsesSQLRows && viewModel.canLocateRows && !connection.safeModeLevel.blocksWrites
    }

    private var columns: [ColumnInfo] { viewModel.columns }
    private var rows: [[String?]] { viewModel.legacyRows }

    private var sortColumnBinding: Binding<String?> {
        Binding(
            get: { viewModel.sortState.columns.first?.name },
            set: { newColumn in
                if let column = newColumn {
                    viewModel.sortState.columns = [SortColumn(name: column, ascending: true)]
                } else {
                    viewModel.sortState.clear()
                }
                Task { await viewModel.applySort() }
            }
        )
    }

    private var sortDirectionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.sortState.columns.first?.ascending ?? true },
            set: { ascending in
                if let current = viewModel.sortState.columns.first {
                    viewModel.sortState.columns = [SortColumn(name: current.name, ascending: ascending)]
                }
                Task { await viewModel.applySort() }
            }
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return searchableContent
            // The root browser stays mounted under this one; SwiftUI leaves two advertisers of one type unspecified.
            .userActivity(SceneIntent.viewTableActivity, isActive: reference == nil && appState.offersHandoff(for: connection)) { activity in
                activity.title = table.name
                activity.isEligibleForHandoff = true
                activity.userInfo = [
                    "connectionId": connection.id.uuidString,
                    "tableName": table.name
                ]
            }
            .toolbar { topToolbar }
            .bottomSafeAreaBar {
                if showsPaginationBar {
                    paginationBar
                }
            }
            .task {
                viewModel.attach(
                    session: session, table: table, databaseType: connection.type,
                    host: connection.host, schema: browserSchema
                )
                if let filters = reference?.filters() {
                    viewModel.seedFilters(filters)
                }
                await viewModel.load(isInitial: true)
                guard reference != nil, !Task.isCancelled else { return }
                if viewModel.takeSingleRowMatch() {
                    showMatchedRow = true
                }
            }
            // A redial or another window's database switch hands this table a new session; a referenced table keeps its schema.
            .onChange(of: BrowseSource(session: session, schema: browserSchema)) { _, source in
                guard source.driver != nil else { return }
                viewModel.attach(
                    session: session, table: table, databaseType: connection.type,
                    host: connection.host, schema: source.schema
                )
                Task { await viewModel.load(isInitial: true) }
            }
            .onChange(of: appState.sessionTransactions.rollBackCount(for: connection.id)) {
                Task { await viewModel.load() }
            }
            // With autocommit off, a MySQL read opens a transaction.
            .onChange(of: viewModel.isLoading || viewModel.isPageLoading) { _, loading in
                guard !loading else { return }
                Task { await coordinator.refreshTransaction() }
            }
            .onDisappear { viewModel.cancel() }
            .sheet(isPresented: $showInsertSheet) { insertSheet }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheetView(
                    filters: $viewModel.filters,
                    logicMode: $viewModel.filterLogicMode,
                    columns: columns,
                    databaseType: connection.type,
                    onApply: { Task { await viewModel.applyFilters() } },
                    onClear: { Task { await viewModel.clearFilters() } }
                )
            }
            .foreignKeyPreview(
                item: $fkPreviewItem,
                session: session,
                coordinator: coordinator,
                databaseType: connection.type,
                allowsOpen: true
            )
            .sheet(isPresented: $showShareSheet) {
                ActivityViewController(items: [shareText])
            }
            .confirmationDialog("Delete Row", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let deleteTarget {
                        Task { await performDelete(deleteTarget) }
                    }
                }
            } message: {
                Text("Are you sure you want to delete this row? This action cannot be undone.")
            }
            .alert(
                viewModel.operationError?.title ?? "Error",
                isPresented: Binding(
                    get: { viewModel.operationError != nil },
                    set: { if !$0 { viewModel.operationError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.operationError?.message ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task { await viewModel.handleSystemMemoryWarning() }
            }
            .onChange(of: MemoryPressureMonitor.shared.currentLevel) { _, level in
                Task { await viewModel.handlePressure(level) }
            }
            .overlay(alignment: .center) {
                if let message = viewModel.memoryWarning, rows.isEmpty, !viewModel.isLoading, viewModel.loadError == nil {
                    ContentUnavailableView {
                        Label("Results Cleared", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reload") {
                            viewModel.dismissMemoryWarning()
                            Task { await viewModel.load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: hapticSuccess)
            .sensoryFeedback(.error, trigger: hapticError)
            .navigationDestination(isPresented: $showStructure) {
                StructureView(table: table, session: session, databaseType: connection.type, schema: viewModel.schema)
                    .transactionBar(for: coordinator)
            }
            .navigationDestination(isPresented: $showMatchedRow) {
                rowDetail(index: 0)
            }
            .alert("Go to Page", isPresented: $showGoToPage) {
                TextField("Page number", text: $goToPageInput)
                    .keyboardType(.numberPad)
                Button("Go") {
                    if let page = Int(goToPageInput) {
                        Task { await viewModel.goToPage(page) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let total = viewModel.pagination.totalRows {
                    let totalPages = (total + viewModel.pagination.pageSize - 1) / viewModel.pagination.pageSize
                    Text("Enter a page number (1-\(totalPages))")
                } else {
                    Text("Enter a page number")
                }
            }
    }

    @ViewBuilder
    private var searchableContent: some View {
        if !browsesSQLRows {
            content
                .tableTitle(table.name, schema: displaySchema)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .tableTitle(table.name, schema: displaySchema)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Search all columns")
                .searchFocused($searchFocused)
                .textInputAutocapitalization(.never)
                .onSubmit(of: .search) {
                    Task { await viewModel.applySearch(searchText) }
                }
                .onChange(of: searchText) { oldValue, newValue in
                    if newValue.isEmpty, !oldValue.isEmpty, viewModel.hasActiveSearch {
                        Task { await viewModel.clearSearch() }
                    }
                }
                .background {
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .accessibilityLabel(Text("Focus search"))
                        .hidden()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let appError = viewModel.loadError {
            ErrorView(error: appError) { await viewModel.load() }
        } else if rows.isEmpty, viewModel.isPageLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty, viewModel.hasActiveSearch {
            ContentUnavailableView.search(text: viewModel.activeSearchText)
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No Data", systemImage: "tray")
            } description: {
                Text("This table is empty.")
            } actions: {
                if canInsertRow {
                    Button("Insert Row") { showInsertSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            rowList
        }
    }

    private var rowList: some View {
        let indexed = IndexedRow.wrap(rows)
        return List {
            ForEach(indexed) { item in
                rowLink(index: item.id, row: item.values)
            }
        }
        .listStyle(.plain)
        .id(viewModel.pagination.currentPage)
        .opacity(viewModel.isPageLoading ? 0.5 : 1)
        .allowsHitTesting(!viewModel.isPageLoading)
        .overlay { if viewModel.isPageLoading { ProgressView() } }
        .animation(.default, value: viewModel.isPageLoading)
        .refreshable { await viewModel.load() }
    }

    private func rowDetail(index: Int) -> some View {
        RowDetailView(
            columns: columns,
            rows: viewModel.window.rows,
            initialIndex: index,
            table: table,
            session: session,
            columnDetails: viewModel.columnDetails,
            databaseType: connection.type,
            schema: viewModel.schema,
            safeModeLevel: { [coordinator] in coordinator.connection.safeModeLevel },
            foreignKeys: viewModel.foreignKeys,
            onSaved: { Task { await viewModel.load() } },
            loadFullValue: { [schema = viewModel.schema] ref in
                guard let session else { return nil }
                return try await viewModel.loadFullValue(
                    driver: session.driver, ref: ref, databaseType: connection.type, schema: schema
                )
            },
            coordinator: coordinator
        )
    }

    private func rowLink(index: Int, row: [String?]) -> some View {
        let cells = viewModel.cells(at: index)
        let deleteKeys = canDeleteRows ? viewModel.rowLocator(forRowAt: index) : nil
        return NavigationLink {
            rowDetail(index: index)
        } label: {
            RowCard(
                columns: columns,
                columnDetails: viewModel.columnDetails,
                row: row,
                previewFieldCount: DuoLayoutResolver.previewFieldCount(for: duoWidthClass)
            )
        }
        .hoverEffect()
        .contextMenu { rowContextMenu(cells: cells) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let deleteKeys {
                Button {
                    confirmDelete(deleteKeys)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .accessibilityActions {
            if let deleteKeys {
                Button("Delete row") { confirmDelete(deleteKeys) }
            }
        }
    }

    private func confirmDelete(_ locator: RowLocator) {
        deleteTarget = locator
        showDeleteConfirmation = true
    }

    @ViewBuilder
    private func rowContextMenu(cells: [Cell]) -> some View {
        if DataBrowserViewModel.canComplete(cells) {
            Menu("Share Row") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.rawValue) {
                        exportCompleted([cells]) { exportColumns, completed in
                            shareText = try ClipboardExporter.exportRow(
                                columns: exportColumns, cells: completed[0],
                                format: format, tableName: table.name,
                                databaseType: connection.type, driver: session?.driver
                            )
                            showShareSheet = true
                        }
                    }
                }
            }
            .disabled(isCompletingCells)
            Menu("Copy Row") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.rawValue) {
                        exportCompleted([cells]) { exportColumns, completed in
                            let text = try ClipboardExporter.exportRow(
                                columns: exportColumns, cells: completed[0],
                                format: format, tableName: table.name,
                                databaseType: connection.type, driver: session?.driver
                            )
                            ClipboardExporter.copyToClipboard(text)
                        }
                    }
                }
            }
            .disabled(isCompletingCells)
        }
        let references = ForeignKeyReference.all(
            foreignKeys: viewModel.foreignKeys, columns: columns,
            cells: cells, sourceSchema: viewModel.schema
        )
        if !references.isEmpty {
            Divider()
            ForEach(references, id: \.name) { entry in
                Button {
                    fkPreviewItem = FKPreviewItem(reference: entry.reference)
                } label: {
                    Label("\(entry.column) -> \(entry.reference.table)", systemImage: "arrow.right.circle")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        if browsesSQLRows {
            sortAndFilterItems
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if browsesSQLRows {
                    Button { showStructure = true } label: {
                        Label("Table Structure", systemImage: "info.circle")
                    }
                    Divider()
                }
                Section("Export") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            exportCompleted(viewModel.window.rows.map(\.cells)) { exportColumns, completed in
                                let text = try ClipboardExporter.exportRows(
                                    columns: exportColumns, rows: completed,
                                    format: format, tableName: table.name,
                                    databaseType: connection.type, driver: session?.driver
                                )
                                ClipboardExporter.copyToClipboard(text)
                            }
                        } label: {
                            Label(format.rawValue, systemImage: "doc.on.clipboard")
                        }
                        .disabled(isCompletingCells)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        if canInsertRow {
            ToolbarItem(placement: .primaryAction) {
                Button { showInsertSheet = true } label: {
                    Label("Insert Row", systemImage: "plus")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var sortAndFilterItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: sortColumnBinding) {
                    Text("Default").tag(String?.none)
                    ForEach(columns, id: \.name) { col in
                        Text(col.name).tag(Optional(col.name))
                    }
                }
                .pickerStyle(.inline)

                if viewModel.sortState.isSorting {
                    Picker("Order", selection: sortDirectionBinding) {
                        Label("Ascending", systemImage: "chevron.up").tag(true)
                        Label("Descending", systemImage: "chevron.down").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Sort", systemImage: viewModel.sortState.isSorting
                    ? "arrow.up.arrow.down.circle.fill"
                    : "arrow.up.arrow.down.circle")
            }
            .disabled(columns.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFilterSheet = true } label: {
                Label("Filter", systemImage: viewModel.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .badge(viewModel.activeFilterCount)
        }
    }

    private var duoWidthClass: DuoWidthClass {
        horizontalSizeClass == .regular ? .regular : .compact
    }

    private var showsPaginationBar: Bool {
        viewModel.showsPaginationBar && !searchFocused
    }

    private var paginationBar: some View {
        PagingBar(
            previousTitle: "Previous Page",
            nextTitle: "Next Page",
            canGoPrevious: viewModel.canGoToPreviousPage,
            canGoNext: viewModel.canGoToNextPage,
            onPrevious: { Task { await viewModel.goToPreviousPage() } },
            onNext: { Task { await viewModel.goToNextPage() } }
        ) {
            pageMenu
        }
    }

    private var pageMenu: some View {
        Menu {
            Section("Rows per Page") {
                ForEach([50, 100, 200, 500], id: \.self) { size in
                    Button {
                        Task { await viewModel.changePageSize(size) }
                    } label: {
                        HStack {
                            Text("\(size) rows")
                            if viewModel.pagination.pageSize == size {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    goToPageInput = ""
                    showGoToPage = true
                } label: {
                    Label("Go to Page...", systemImage: "arrow.right.to.line")
                }
            }
        } label: {
            Text(viewModel.paginationLabel)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var insertSheet: some View {
        InsertRowView(
            table: table,
            columnDetails: viewModel.columnDetails,
            session: session,
            databaseType: connection.type,
            schema: viewModel.schema,
            safeModeLevel: { [coordinator] in coordinator.connection.safeModeLevel },
            onInserted: { Task { await viewModel.load() } }
        )
    }

    // Rows that cannot all be completed skip the reads: the exporter refuses them anyway.
    private func exportCompleted(
        _ pageRows: [[Cell]],
        export: @escaping @MainActor ([ColumnInfo], [[Cell]]) throws -> Void
    ) {
        guard !isCompletingCells else { return }
        let exportColumns = columns
        let driver = session?.driver
        isCompletingCells = true
        Task {
            defer { isCompletingCells = false }
            do {
                var completed = pageRows
                if let driver, pageRows.allSatisfy(DataBrowserViewModel.canComplete) {
                    completed = try await viewModel.completeRows(pageRows, driver: driver)
                }
                try export(exportColumns, completed)
            } catch let error where error is ClipboardExporter.IncompleteValues || error is ClipboardExporter.TooLarge
                        || error is CellLookupError {
                viewModel.operationError = AppError(
                    category: .query,
                    title: String(localized: "Cannot Export"),
                    message: error.localizedDescription,
                    recovery: nil,
                    underlying: error
                )
                hapticError.toggle()
            } catch {
                viewModel.operationError = ErrorClassifier.classify(
                    error,
                    context: ErrorContext(operation: "exportRows", databaseType: connection.type, host: connection.host)
                )
                hapticError.toggle()
            }
        }
    }

    private func performDelete(_ locator: RowLocator) async {
        let success = await coordinator.track(failed: { !$0 }) { await viewModel.deleteRow(locator) }
        if success {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }
}

private struct BrowseSource: Equatable {
    let driver: ObjectIdentifier?
    let schema: String?

    init(session: ConnectionSession?, schema: String?) {
        driver = session.map { ObjectIdentifier($0.driver) }
        self.schema = schema
    }
}
