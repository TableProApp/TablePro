import SwiftUI
import TableProDatabase
import TableProModels
import TableProQuery

struct DataBrowserView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let table: TableInfo

    private var connection: DatabaseConnection { coordinator.connection }
    private var session: ConnectionSession? { coordinator.session }

    @State private var viewModel = DataBrowserViewModel()
    @State private var searchText = ""
    @State private var showInsertSheet = false
    @State private var showFilterSheet = false
    @State private var showShareSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showStructure = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var deleteTarget: [(column: String, value: String)]?
    @State private var fkPreviewItem: FKPreviewItem?
    @State private var shareText = ""
    @State private var hapticSuccess = false
    @State private var hapticError = false

    private var isView: Bool { table.type == .view || table.type == .materializedView }
    private var isRedis: Bool { connection.type == .redis }
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
            .userActivity("com.TablePro.viewTable") { activity in
                activity.title = table.name
                activity.isEligibleForHandoff = true
                activity.userInfo = [
                    "connectionId": connection.id.uuidString,
                    "tableName": table.name
                ]
            }
            .toolbar { topToolbar }
            .toolbar(rows.isEmpty && !viewModel.hasActiveSearch && !viewModel.hasActiveFilters ? .hidden : .visible, for: .bottomBar)
            .toolbar { paginationToolbar }
            .task {
                viewModel.attach(session: session, table: table, databaseType: connection.type, host: connection.host)
                await viewModel.load(isInitial: true)
            }
            .onDisappear { viewModel.cancel() }
            .sheet(isPresented: $showInsertSheet) { insertSheet }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheetView(
                    filters: $viewModel.filters,
                    logicMode: $viewModel.filterLogicMode,
                    columns: columns,
                    onApply: { Task { await viewModel.applyFilters() } },
                    onClear: { Task { await viewModel.clearFilters() } }
                )
            }
            .sheet(item: $fkPreviewItem) { item in
                FKPreviewView(
                    fk: item.fk,
                    value: item.value,
                    session: session,
                    databaseType: connection.type
                )
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityViewController(items: [shareText])
            }
            .confirmationDialog("Delete Row", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let pkValues = deleteTarget {
                        Task { await performDelete(pkValues) }
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
                StructureView(table: table, session: session, databaseType: connection.type)
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
        if isRedis {
            content
                .navigationTitle(table.name)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .navigationTitle(table.name)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Search all columns")
                .textInputAutocapitalization(.never)
                .onSubmit(of: .search) {
                    Task { await viewModel.applySearch(searchText) }
                }
                .onChange(of: searchText) { oldValue, newValue in
                    if newValue.isEmpty, !oldValue.isEmpty, viewModel.hasActiveSearch {
                        Task { await viewModel.clearSearch() }
                    }
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
        } else if rows.isEmpty, viewModel.hasActiveSearch {
            ContentUnavailableView.search(text: viewModel.activeSearchText)
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No Data", systemImage: "tray")
            } description: {
                Text("This table is empty.")
            } actions: {
                if !isView && !connection.safeModeLevel.blocksWrites {
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

    private func rowLink(index: Int, row: [String?]) -> some View {
        NavigationLink {
            RowDetailView(
                columns: columns,
                rows: viewModel.window.rows,
                initialIndex: index,
                table: table,
                session: session,
                columnDetails: viewModel.columnDetails,
                databaseType: connection.type,
                safeModeLevel: connection.safeModeLevel,
                foreignKeys: viewModel.foreignKeys,
                onSaved: { Task { await viewModel.load() } },
                loadFullValue: { ref in
                    guard let session else { return nil }
                    return try await viewModel.loadFullValue(driver: session.driver, ref: ref)
                }
            )
        } label: {
            RowCard(columns: columns, columnDetails: viewModel.columnDetails, row: row)
        }
        .hoverEffect()
        .contextMenu { rowContextMenu(row: row) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isView && viewModel.hasPrimaryKeys && !connection.safeModeLevel.blocksWrites {
                Button {
                    deleteTarget = viewModel.primaryKeyValues(for: row)
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(row: [String?]) -> some View {
        Menu("Share Row") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.rawValue) {
                    shareText = ClipboardExporter.exportRow(
                        columns: columns, row: row,
                        format: format, tableName: table.name
                    )
                    showShareSheet = true
                }
            }
        }
        Menu("Copy Row") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.rawValue) {
                    let text = ClipboardExporter.exportRow(
                        columns: columns, row: row,
                        format: format, tableName: table.name
                    )
                    ClipboardExporter.copyToClipboard(text)
                }
            }
        }
        let rowFKs = viewModel.foreignKeys.filter { fk in
            guard let colIndex = columns.firstIndex(where: { $0.name == fk.column }),
                  colIndex < row.count,
                  row[colIndex] != nil else { return false }
            return true
        }
        if !rowFKs.isEmpty {
            Divider()
            ForEach(rowFKs, id: \.name) { fk in
                Button {
                    if let colIndex = columns.firstIndex(where: { $0.name == fk.column }),
                       colIndex < row.count,
                       let value = row[colIndex] {
                        fkPreviewItem = FKPreviewItem(fk: fk, value: value)
                    }
                } label: {
                    Label("\(fk.column) -> \(fk.referencedTable)", systemImage: "arrow.right.circle")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
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
                Image(systemName: viewModel.sortState.isSorting
                    ? "arrow.up.arrow.down.circle.fill"
                    : "arrow.up.arrow.down.circle")
                    .accessibilityLabel(Text("Sort"))
            }
            .disabled(columns.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFilterSheet = true } label: {
                Image(systemName: viewModel.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .accessibilityLabel(Text("Filter"))
            }
            .badge(viewModel.activeFilterCount)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showStructure = true } label: {
                    Label("Table Structure", systemImage: "info.circle")
                }
                Divider()
                Section("Export") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            let text = ClipboardExporter.exportRows(
                                columns: columns, rows: rows,
                                format: format, tableName: table.name
                            )
                            ClipboardExporter.copyToClipboard(text)
                        } label: {
                            Label(format.rawValue, systemImage: "doc.on.clipboard")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        if !isView && !connection.safeModeLevel.blocksWrites {
            ToolbarItem(placement: .primaryAction) {
                Button { showInsertSheet = true } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(Text("Insert Row"))
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var paginationToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { Task { await viewModel.goToPreviousPage() } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(viewModel.pagination.currentPage == 0 || viewModel.isLoading)

            Spacer()

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

            Spacer()

            Button { Task { await viewModel.goToNextPage() } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.pagination.hasNextPage || viewModel.isLoading)
        }
    }

    private var insertSheet: some View {
        InsertRowView(
            table: table,
            columnDetails: viewModel.columnDetails,
            session: session,
            databaseType: connection.type,
            onInserted: { Task { await viewModel.load() } }
        )
    }

    private func performDelete(_ pkValues: [(column: String, value: String)]) async {
        let success = await viewModel.deleteRow(pkValues: pkValues)
        if success {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }
}
