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
    // Not persisted. This search runs on the server and is applied on submit, so a value restored
    // into the field would name a filter the rows on screen were never fetched under.
    @State private var searchText = ""
    @State private var searchFocused = false
    @State private var showInsertSheet = false
    @State private var showFilterSheet = false
    @State private var showShareSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showStructure = false
    @State private var showMatchedRow = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var deleteTarget: PendingRowDelete?
    @State private var fkPreviewItem: FKPreviewItem?
    @State private var shareText = ""
    @State private var isCompletingCells = false
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var exportItem: MobileExportItem?
    @State private var showRowFilePicker = false
    @State private var importFile: IdentifiableURL?
    @State private var pendingSelectionDelete: PendingRowsDelete?
    @AppStorage(AppPreferences.rowLayoutKey) private var preferredLayout: RowLayout?

    private var activeSchema: String? {
        coordinator.tableQualifier
    }

    private var browserSchema: String? {
        if let reference { return reference.schema }
        return activeSchema
    }

    // A SQL Server foreign key never leaves its database, so a referenced table is read where the key was.
    private var browserDatabase: String? {
        if let reference { return reference.database }
        return coordinator.tableDatabase
    }

    private var displaySchema: String? {
        reference?.displaySchema(current: activeSchema)
    }

    // Asked of the kind rather than compared against the two view cases, so a MariaDB sequence,
    // which refuses UPDATE and DELETE with ERROR 1031, is read-only here as it is on Mac.
    private var allowsRowEditing: Bool { table.type.allowsRowEditing }
    private var browseMode: TableBrowseMode { TableBrowseMode(driver: session?.driver) }
    private var browsesSQLRows: Bool { browseMode == .sql }

    // Both entry points ask this. A key's contents take no `INSERT`, and the form cannot be filled
    // in before the column list has arrived.
    private var canInsertRow: Bool {
        allowsRowEditing && browsesSQLRows
            && !connection.safeModeLevel.blocksWrites && !viewModel.columnDetails.isEmpty
    }

    private var canDeleteRows: Bool {
        allowsRowEditing && browsesSQLRows && viewModel.canLocateRows && !connection.safeModeLevel.blocksWrites
    }

    private var columns: [ColumnInfo] { viewModel.columns }
    private var rows: [Row] { viewModel.window.rows }

    private var isSelecting: Bool { viewModel.selection.isActive }

    private var canExport: Bool {
        session.map { ExportObjectListing.supportsExport($0.driver) } ?? false
    }

    private var canExportTable: Bool {
        session.map { ExportObjectListing.supportsTableExport($0.driver) } ?? false
    }

    // Read-Only hides it, as it hides Insert Row; Confirm Writes asks when the import starts.
    private var canImportRows: Bool {
        allowsRowEditing && browsesSQLRows && !connection.safeModeLevel.blocksWrites && canExport
            && !MobileImportFormats.rowFormats(for: connection.type).isEmpty
    }

    private var pageReads: DataBrowserViewModel.SessionReadTracker {
        let viewModel = viewModel
        return coordinator.trackPageRead { viewModel.loadError != nil }
    }

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
            .toolbar { selectionBar }
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .navigationBarBackButtonHidden(isSelecting)
            .bottomSafeAreaBar {
                if showsPaginationBar && !isSelecting {
                    paginationBar
                }
            }
            .task {
                viewModel.attach(
                    session: session, table: table, databaseType: connection.type,
                    host: connection.host, schema: browserSchema, database: browserDatabase, trackRead: pageReads
                )
                if let filters = reference?.filters() {
                    viewModel.seedFilters(filters)
                }
                await viewModel.load(isInitial: true)
            }
            // Pushed when the one row lands, not after the key read and the count that follow it.
            .onChange(of: viewModel.hasSingleRowMatch) { _, found in
                guard found, reference != nil, viewModel.takeSingleRowMatch() else { return }
                showMatchedRow = true
            }
            // A redial or another window's switch hands this table a new session; a referenced table keeps its schema and database.
            .onChange(of: BrowseSource(session: session, schema: browserSchema, database: browserDatabase)) { _, source in
                // The confirmation names a row of the table this browser showed before.
                showDeleteConfirmation = false
                deleteTarget = nil
                pendingSelectionDelete = nil
                guard source.driver != nil else { return }
                viewModel.attach(
                    session: session, table: table, databaseType: connection.type,
                    host: connection.host, schema: source.schema, database: source.database, trackRead: pageReads
                )
                Task { await viewModel.load(isInitial: true) }
            }
            .onChange(of: appState.sessionTransactions.rollBackCount(for: connection.id)) {
                Task { await viewModel.load() }
            }
            .onDisappear { viewModel.cancel() }
            .sheet(isPresented: $showInsertSheet) { insertSheet }
            .sheet(item: $exportItem) { item in
                MobileExportSheet(
                    input: item.input,
                    environment: .live(connectionManager: appState.connectionManager, coordinator: coordinator)
                )
            }
            .fileImporter(
                isPresented: $showRowFilePicker,
                allowedContentTypes: ImportPickerTypes.contentTypes(for: MobileImportFormats.rowFormats(for: connection.type)),
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                importFile = IdentifiableURL(url: url)
            }
            .sheet(item: $importFile) { item in
                MobileImportSheet(fileURL: item.url, presetTable: table.name) {
                    Task { await viewModel.load() }
                }
                .environment(appState)
                .environment(coordinator)
            }
            .confirmationDialog(
                Text("^[Delete \(pendingSelectionDelete?.locators.count ?? 0) Row](inflect: true)?"),
                isPresented: Binding(
                    get: { pendingSelectionDelete != nil },
                    set: { if !$0 { pendingSelectionDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingSelectionDelete
            ) { pending in
                Button(role: .destructive) {
                    Task { await performSelectionDelete(pending) }
                } label: {
                    Text("^[Delete \(pending.locators.count) Row](inflect: true)")
                }
            } message: { _ in
                Text("This action cannot be undone.")
            }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheetView(
                    filters: $viewModel.filters,
                    logicMode: $viewModel.filterLogicMode,
                    columns: columns,
                    databaseType: connection.type,
                    operators: (session?.driver as? any DriverQueryBuilding)?.filterOperators ?? FilterOperator.allCases,
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
                StructureView(
                    table: table, session: session, databaseType: connection.type, schema: viewModel.schema,
                    database: viewModel.database
                )
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
            titled(content)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            titled(content)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) {
                    LiteralSearchField("Search all columns", text: $searchText, isEditing: $searchFocused) {
                        Task { await viewModel.applySearch(searchText) }
                    }
                    .padding(.horizontal, 8)
                    .background(.bar)
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
        } else if viewModel.isPastTheEnd {
            ContentUnavailableView {
                Label("No Rows on This Page", systemImage: "tray")
            } description: {
                Text("This page is past the last row.")
            } actions: {
                Button("Go to First Page") {
                    Task { await viewModel.goToPage(1) }
                }
                .buttonStyle(.borderedProminent)
            }
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
            rowsView
        }
    }

    private func titled(_ view: some View) -> some View {
        view.tableTitle(
            table.name,
            schema: displaySchema,
            replacement: isSelecting ? Text("^[\(viewModel.selection.count) Row](inflect: true) Selected") : nil
        )
    }

    private var rowLayout: RowLayout {
        RowLayout.resolved(preferred: preferredLayout, idiom: UIDevice.current.userInterfaceIdiom)
    }

    @ViewBuilder
    private var rowsView: some View {
        switch rowLayout {
        case .cards:
            pageContainer(rowList)
        case .grid:
            pageContainer(rowGrid)
        }
    }

    private var rowList: some View {
        let rows = rows
        @Bindable var viewModel = viewModel
        return List(selection: RowSelectionBinding.rows($viewModel.selection)) {
            ForEach(rows.indices, id: \.self) { index in
                rowLink(index: index, row: rows[index].displayValues())
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, RowSelectionBinding.editMode($viewModel.selection))
    }

    private var rowGrid: some View {
        let primaryKeys = primaryKeyNames
        return RowGrid(
            columns: columns,
            window: viewModel.window,
            keyColumn: RowKey.columnIndex(columns: columns, primaryKeys: primaryKeys),
            selectedRows: isSelecting ? viewModel.selection.rows : nil
        ) { index, line in
            if isSelecting {
                let isSelected = viewModel.selection.contains(index)
                Button {
                    viewModel.selection.toggle(index)
                } label: {
                    line
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                NavigationLink {
                    rowDetail(index: index)
                } label: {
                    line
                }
                .hoverEffect()
                .contextMenu {
                    rowContextMenu(index: index)
                } preview: {
                    // The row itself can be thousands of points wide; the lift preview shows its card.
                    RowCard(
                        columns: columns,
                        columnDetails: viewModel.columnDetails,
                        row: rows.indices.contains(index) ? rows[index].displayValues() : [],
                        previewFieldCount: DuoLayoutResolver.regularPreviewFieldCount
                    )
                    .padding()
                    .frame(maxWidth: 360, alignment: .leading)
                }
                .accessibilityActions { deleteAccessibilityAction(index: index) }
            }
        }
    }

    private var primaryKeyNames: Set<String> {
        Set(viewModel.columnDetails.filter(\.isPrimaryKey).map(\.name))
    }

    private func pageContainer(_ rows: some View) -> some View {
        rows
            .id(viewModel.pagination.currentPage)
            .opacity(viewModel.isPageLoading ? 0.5 : 1)
            .allowsHitTesting(!viewModel.isPageLoading)
            .overlay { if viewModel.isPageLoading { ProgressView() } }
            .motionAnimation(.default, value: viewModel.isPageLoading)
            .refreshable { await viewModel.load() }
    }

    private func rowDetail(index: Int) -> some View {
        let viewModel = viewModel
        return RowDetailView(
            columns: columns,
            rows: viewModel.window.rows,
            initialIndex: index,
            table: table,
            session: session,
            columnDetails: viewModel.columnDetails,
            databaseType: connection.type,
            schema: viewModel.schema,
            database: viewModel.database,
            safeModeLevel: { [coordinator] in coordinator.connection.safeModeLevel },
            foreignKeys: viewModel.foreignKeys,
            onSaved: { Task { await viewModel.load() } },
            loadFullValue: { [schema = viewModel.schema, database = viewModel.database] ref in
                guard let session else { return nil }
                // With autocommit off, a MySQL read opens a transaction; a failed read refreshes too, and never redials.
                do {
                    let value = try await viewModel.loadFullValue(
                        driver: session.driver, ref: ref, databaseType: connection.type, schema: schema,
                        database: database
                    )
                    await coordinator.refreshTransaction()
                    return value
                } catch {
                    await coordinator.refreshTransaction()
                    throw error
                }
            },
            coordinator: coordinator
        )
    }

    private func rowLink(index: Int, row: [String?]) -> some View {
        let deleteKeys = deletableRow(at: index)
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
        .contextMenu { rowContextMenu(index: index) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting, let deleteKeys {
                Button {
                    confirmDelete(deleteKeys)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .accessibilityActions { deleteAccessibilityAction(index: index) }
    }

    private func deletableRow(at index: Int) -> RowLocator? {
        canDeleteRows ? viewModel.rowLocator(forRowAt: index) : nil
    }

    @ViewBuilder
    private func deleteAccessibilityAction(index: Int) -> some View {
        if let locator = deletableRow(at: index) {
            Button("Delete row") { confirmDelete(locator) }
        }
    }

    private func confirmDelete(_ locator: RowLocator) {
        deleteTarget = PendingRowDelete(locator: locator, source: viewModel.rowSource)
        showDeleteConfirmation = true
    }

    @ViewBuilder
    private func rowContextMenu(index: Int) -> some View {
        let cells = viewModel.cells(at: index)
        if DataBrowserViewModel.canComplete(cells) {
            Menu("Share Row") {
                ForEach(ExportFormat.offered(for: connection.type)) { format in
                    Button(format.rawValue) {
                        exportCompleted([cells], asOneRow: true, format: format) { text in
                            shareText = text
                            showShareSheet = true
                        }
                    }
                }
            }
            .disabled(isCompletingCells)
            Menu("Copy Row") {
                ForEach(ExportFormat.offered(for: connection.type)) { format in
                    Button(format.rawValue) {
                        exportCompleted([cells], asOneRow: true, format: format) { text in
                            ClipboardExporter.copyToClipboard(text)
                        }
                    }
                }
            }
            .disabled(isCompletingCells)
        }
        let references = ForeignKeyReference.all(
            foreignKeys: viewModel.foreignKeys, columns: columns,
            cells: cells, sourceSchema: viewModel.schema, sourceDatabase: viewModel.database
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
        if let locator = deletableRow(at: index) {
            Divider()
            Button("Delete Row", systemImage: "trash", role: .destructive) { confirmDelete(locator) }
        }
    }

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let selectsAll = viewModel.selection.selectsAll(of: rows.count)
                Button(selectsAll ? String(localized: "Deselect All") : String(localized: "Select All")) {
                    if selectsAll {
                        viewModel.selection.clearRows()
                    } else {
                        viewModel.selection.selectAll(count: rows.count)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.selection.end()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
            }
        } else {
            browsingToolbar
        }
    }

    @ToolbarContentBuilder
    private var browsingToolbar: some ToolbarContent {
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
                Button {
                    viewModel.selection.begin()
                } label: {
                    Label("Select Rows", systemImage: "checkmark.circle")
                }
                .disabled(rows.isEmpty)
                RowLayoutPicker()
                Divider()
                if canExportTable || canImportRows {
                    Section {
                        if canExportTable {
                            Button { presentTableExport() } label: {
                                Label("Export…", systemImage: "square.and.arrow.up")
                            }
                        }
                        if canImportRows {
                            Button { showRowFilePicker = true } label: {
                                Label("Import Rows…", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
                Section("Copy Page") {
                    ForEach(ExportFormat.offered(for: connection.type)) { format in
                        Button {
                            exportCompleted(viewModel.window.rows.map(\.cells), asOneRow: false, format: format) { text in
                                ClipboardExporter.copyToClipboard(text)
                            }
                        } label: {
                            Label(format.rawValue, systemImage: "doc.on.clipboard")
                        }
                        .disabled(isCompletingCells)
                    }
                }
            } label: {
                Label("More", systemImage: ToolbarSymbols.more())
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
    private var selectionBar: some ToolbarContent {
        if isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                let indices = viewModel.selection.indices(within: rows.count)
                Button {
                    presentSelectionExport(indices)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(indices.isEmpty || !canExport)
                Spacer()
                Menu {
                    ForEach(ExportFormat.offered(for: connection.type)) { format in
                        Button(format.rawValue) {
                            exportCompleted(indices.map(viewModel.cells(at:)), asOneRow: false, format: format) { text in
                                ClipboardExporter.copyToClipboard(text)
                            }
                        }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(indices.isEmpty || isCompletingCells)
                if canDeleteRows {
                    Spacer()
                    Button(role: .destructive) {
                        confirmSelectionDelete(indices)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(indices.isEmpty || viewModel.rowLocators(at: indices) == nil)
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
                Label("Sort", systemImage: ToolbarSymbols.sort(isActive: viewModel.sortState.isSorting))
            }
            .disabled(columns.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFilterSheet = true } label: {
                Label("Filter", systemImage: ToolbarSymbols.filter(isActive: viewModel.hasActiveFilters))
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
            database: viewModel.database,
            safeModeLevel: { [coordinator] in coordinator.connection.safeModeLevel },
            onInserted: { Task { await viewModel.load() } }
        )
    }

    // Rows that cannot all be completed skip the reads: the exporter refuses them anyway.
    private func exportCompleted(
        _ pageRows: [[Cell]],
        asOneRow: Bool,
        format: ExportFormat,
        deliver: @escaping (String) -> Void
    ) {
        guard !isCompletingCells else { return }
        let exportColumns = columns
        let driver = session?.driver
        let tableName = table.name
        let databaseType = connection.type
        let columnDetails = viewModel.columnDetails
        isCompletingCells = true
        Task {
            defer { isCompletingCells = false }
            do {
                var completed = pageRows
                if let driver, pageRows.allSatisfy(DataBrowserViewModel.canComplete) {
                    completed = try await viewModel.completeRows(pageRows, driver: driver)
                }
                deliver(try await Self.exportText(
                    completed, columns: exportColumns, asOneRow: asOneRow, format: format,
                    tableName: tableName, databaseType: databaseType, driver: driver, columnDetails: columnDetails
                ))
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

    // Off the main actor, so a page of 500 rows formats without holding up the screen.
    @concurrent
    nonisolated private static func exportText(
        _ rows: [[Cell]],
        columns: [ColumnInfo],
        asOneRow: Bool,
        format: ExportFormat,
        tableName: String,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?,
        columnDetails: [ColumnInfo]
    ) async throws -> String {
        if asOneRow, let cells = rows.first {
            return try ClipboardExporter.exportRow(
                columns: columns, cells: cells, format: format, tableName: tableName,
                databaseType: databaseType, driver: driver, columnDetails: columnDetails
            )
        }
        return try ClipboardExporter.exportRows(
            columns: columns, rows: rows, format: format, tableName: tableName,
            databaseType: databaseType, driver: driver, columnDetails: columnDetails
        )
    }

    // MARK: - Export and Selection

    private var exportDatabase: String? {
        viewModel.database ?? (coordinator.activeDatabase.isEmpty ? nil : coordinator.activeDatabase)
    }

    private var exportSchema: String? {
        coordinator.supportsSchemas ? viewModel.schema : nil
    }

    private func exportInput(title: String, scopes: [ExportScopeOption]) -> MobileExportInput {
        MobileExportInput(
            title: title,
            fileName: table.name,
            connectionId: connection.id,
            databaseType: connection.type,
            database: exportDatabase,
            schema: exportSchema,
            safeModeLevel: connection.safeModeLevel,
            scopes: scopes
        )
    }

    private func presentTableExport() {
        var scopes: [ExportScopeOption] = []
        if viewModel.narrowsRows, let query = viewModel.exportSelect() {
            scopes.append(ExportScopeOption(
                kind: .currentView,
                source: .query(query),
                detail: String(localized: "Every row that matches the search, filter and sort, not only this page.")
            ))
        }
        scopes.append(ExportScopeOption(kind: .wholeTable, source: .table(table.name)))
        exportItem = MobileExportItem(input: exportInput(title: String(localized: "Export Table"), scopes: scopes))
    }

    private func presentSelectionExport(_ indices: [Int]) {
        do {
            let source = try viewModel.selectedRowsExportSource(indices)
            let detail = String(AttributedString(localized: "^[\(indices.count) row](inflect: true) selected.").characters)
            exportItem = MobileExportItem(input: exportInput(
                title: String(localized: "Export Rows"),
                scopes: [ExportScopeOption(kind: .selectedRows, source: source, detail: detail)]
            ))
        } catch {
            viewModel.operationError = AppError(
                category: .query,
                title: String(localized: "Cannot Export"),
                message: error.localizedDescription,
                recovery: nil,
                underlying: error
            )
            hapticError.toggle()
        }
    }

    private func confirmSelectionDelete(_ indices: [Int]) {
        guard let locators = viewModel.rowLocators(at: indices), !locators.isEmpty else { return }
        pendingSelectionDelete = PendingRowsDelete(locators: locators, source: viewModel.rowSource)
    }

    private func performSelectionDelete(_ pending: PendingRowsDelete) async {
        guard !viewModel.refusesDelete(raisedOn: pending.source) else {
            hapticError.toggle()
            return
        }
        let total = pending.locators.count
        let deleted = await coordinator.track(failed: { $0 < total }) { await viewModel.deleteRows(pending.locators) }
        if deleted == total {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }

    private func performDelete(_ pending: PendingRowDelete) async {
        guard !viewModel.refusesDelete(raisedOn: pending.source) else {
            hapticError.toggle()
            return
        }
        let locator = pending.locator
        let success = await coordinator.track(failed: { !$0 }) { await viewModel.deleteRow(locator) }
        if success {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }
}

private struct PendingRowDelete {
    let locator: RowLocator
    let source: DataBrowserViewModel.RowSource
}

private struct PendingRowsDelete {
    let locators: [RowLocator]
    let source: DataBrowserViewModel.RowSource
}

private struct BrowseSource: Equatable {
    let driver: ObjectIdentifier?
    let schema: String?
    let database: String?

    init(session: ConnectionSession?, schema: String?, database: String?) {
        driver = session.map { ObjectIdentifier($0.driver) }
        self.schema = schema
        self.database = database
    }
}
