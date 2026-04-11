//
//  DataBrowserView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels
import TableProQuery

struct DataBrowserView: View {
    let connection: DatabaseConnection
    let table: TableInfo
    let session: ConnectionSession?

    private static let logger = Logger(subsystem: "com.TablePro", category: "DataBrowserView")

    @State private var columns: [ColumnInfo] = []
    @State private var columnDetails: [ColumnInfo] = []
    @State private var rows: [[String?]] = []
    @State private var isLoading = true
    @State private var isPageLoading = false
    @State private var appError: AppError?
    @State private var pagination = PaginationState(pageSize: 100, currentPage: 0)
    @State private var showInsertSheet = false
    @State private var deleteTarget: [(column: String, value: String)]?
    @State private var showDeleteConfirmation = false
    @State private var operationError: AppError?
    @State private var showOperationError = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var searchText = ""
    @State private var activeSearchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var filters: [TableFilter] = []
    @State private var filterLogicMode: FilterLogicMode = .and
    @State private var showFilterSheet = false
    @State private var sortState = SortState()
    @State private var rowListGeneration = 0
    @State private var foreignKeys: [ForeignKeyInfo] = []
    @State private var fkPreviewItem: FKPreviewItem?
    @State private var memoryWarningMessage: String?
    @State private var hapticSuccess = false
    @State private var hapticError = false

    private var isView: Bool {
        table.type == .view || table.type == .materializedView
    }

    private var hasPrimaryKeys: Bool {
        columnDetails.contains(where: \.isPrimaryKey)
    }

    private var paginationLabel: String {
        guard !rows.isEmpty else { return "" }
        let start = pagination.currentOffset + 1
        let end = pagination.currentOffset + rows.count
        if let total = pagination.totalRows {
            return "\(start)–\(end) of \(total)"
        }
        return "\(start)–\(end)"
    }

    private var hasActiveSearch: Bool {
        !activeSearchText.isEmpty
    }

    private var isRedis: Bool {
        connection.type == .redis
    }

    private var hasActiveFilters: Bool {
        filters.contains { $0.isEnabled && $0.isValid }
    }

    private var sortColumnBinding: Binding<String?> {
        Binding(
            get: { sortState.columns.first?.name },
            set: { newColumn in
                if let column = newColumn {
                    sortState.columns = [SortColumn(name: column, ascending: true)]
                } else {
                    sortState.clear()
                }
                applySort()
            }
        )
    }

    private var sortDirectionBinding: Binding<Bool> {
        Binding(
            get: { sortState.columns.first?.ascending ?? true },
            set: { ascending in
                if let current = sortState.columns.first {
                    sortState.columns = [SortColumn(name: current.name, ascending: ascending)]
                }
                applySort()
            }
        )
    }

    var body: some View {
        searchableContent
            .toolbar { topToolbar }
            .toolbar(rows.isEmpty && !hasActiveSearch && !hasActiveFilters ? .hidden : .visible, for: .bottomBar)
            .toolbar { paginationToolbar }
            .task { await loadData(isInitial: true) }
            .sheet(isPresented: $showInsertSheet) { insertSheet }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheetView(
                    filters: $filters,
                    logicMode: $filterLogicMode,
                    columns: columns,
                    onApply: { applyFilters() },
                    onClear: { clearFilters() }
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
            .confirmationDialog("Delete Row", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let pkValues = deleteTarget {
                        Task { await deleteRow(withPKs: pkValues) }
                    }
                }
            } message: {
                Text("Are you sure you want to delete this row? This action cannot be undone.")
            }
            .alert(operationError?.title ?? "Error", isPresented: $showOperationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(operationError?.message ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                guard !rows.isEmpty else { return }
                Self.logger.warning("Memory warning received — clearing \(rows.count) rows")
                rows = []
                memoryWarningMessage = String(localized: "Results cleared due to memory pressure.")
            }
            .overlay(alignment: .center) {
                if let message = memoryWarningMessage, rows.isEmpty, !isLoading, appError == nil {
                    ContentUnavailableView {
                        Label("Results Cleared", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reload") {
                            memoryWarningMessage = nil
                            Task { await loadData() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: hapticSuccess)
            .sensoryFeedback(.error, trigger: hapticError)
            .alert("Go to Page", isPresented: $showGoToPage) {
                TextField("Page number", text: $goToPageInput)
                    .keyboardType(.numberPad)
                Button("Go") { goToPage() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let total = pagination.totalRows {
                    let totalPages = (total + pagination.pageSize - 1) / pagination.pageSize
                    Text("Enter a page number (1–\(totalPages))")
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
                .onSubmit(of: .search) { applySearch() }
                .onChange(of: searchText) { oldValue, newValue in
                    if newValue.isEmpty, !oldValue.isEmpty, hasActiveSearch {
                        clearSearch()
                    }
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let appError {
            ErrorView(error: appError) { await loadData() }
        } else if rows.isEmpty, hasActiveSearch {
            ContentUnavailableView.search(text: activeSearchText)
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

    private var activeFilterCount: Int {
        filters.filter { $0.isEnabled && $0.isValid }.count
    }

    private var rowList: some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                NavigationLink {
                    RowDetailView(
                        columns: columns,
                        rows: rows,
                        initialIndex: index,
                        table: table,
                        session: session,
                        columnDetails: columnDetails,
                        databaseType: connection.type,
                        safeModeLevel: connection.safeModeLevel,
                        foreignKeys: foreignKeys,
                        onSaved: { Task { await loadData() } }
                    )
                } label: {
                    RowCard(
                        columns: columns,
                        columnDetails: columnDetails,
                        row: row
                    )
                }
                .contextMenu {
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
                    if !foreignKeys.isEmpty {
                        let rowFKs = foreignKeys.filter { fk in
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
                                    Label("\(fk.column) → \(fk.referencedTable)", systemImage: "arrow.right.circle")
                                }
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isView && hasPrimaryKeys && !connection.safeModeLevel.blocksWrites {
                        Button {
                            deleteTarget = primaryKeyValues(for: row)
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
        .id(rowListGeneration)
        .opacity(isPageLoading ? 0.5 : 1)
        .allowsHitTesting(!isPageLoading)
        .overlay { if isPageLoading { ProgressView() } }
        .animation(.default, value: isPageLoading)
        .refreshable { await loadData() }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
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
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .accessibilityLabel(Text("Export"))
            }
            .disabled(rows.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: sortColumnBinding) {
                    Text("Default").tag(String?.none)
                    ForEach(columns, id: \.name) { col in
                        Text(col.name).tag(Optional(col.name))
                    }
                }
                .pickerStyle(.inline)

                if sortState.isSorting {
                    Picker("Order", selection: sortDirectionBinding) {
                        Label("Ascending", systemImage: "chevron.up").tag(true)
                        Label("Descending", systemImage: "chevron.down").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Image(systemName: sortState.isSorting
                    ? "arrow.up.arrow.down.circle.fill"
                    : "arrow.up.arrow.down.circle")
                    .accessibilityLabel(Text("Sort"))
            }
            .disabled(columns.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFilterSheet = true } label: {
                Image(systemName: hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .accessibilityLabel(Text("Filter"))
            }
            .badge(activeFilterCount)
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                StructureView(table: table, session: session, databaseType: connection.type)
            } label: {
                Image(systemName: "info.circle")
                    .accessibilityLabel(Text("Table Structure"))
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
            Button { Task { await goToPreviousPage() } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(pagination.currentPage == 0 || isLoading)

            Spacer()

            Menu {
                Section("Rows per Page") {
                    ForEach([50, 100, 200, 500], id: \.self) { size in
                        Button {
                            changePageSize(size)
                        } label: {
                            HStack {
                                Text("\(size) rows")
                                if pagination.pageSize == size {
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
                Text(paginationLabel)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Spacer()

            Button { Task { await goToNextPage() } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!pagination.hasNextPage || isLoading)
        }
    }

    private var insertSheet: some View {
        InsertRowView(
            table: table,
            columnDetails: columnDetails,
            session: session,
            databaseType: connection.type,
            onInserted: { Task { await loadData() } }
        )
    }

    // MARK: - Data Loading

    private func loadData(isInitial: Bool = false) async {
        guard let session else {
            appError = AppError(
                category: .config,
                title: String(localized: "Not Connected"),
                message: String(localized: "No active database session."),
                recovery: String(localized: "Go back and reconnect to the database."),
                underlying: nil
            )
            isLoading = false
            return
        }

        if isInitial || rows.isEmpty { isLoading = true }
        appError = nil

        do {
            let query: String
            if hasActiveSearch {
                let searchableColumns = columns.filter { col in
                    let upper = col.typeName.uppercased()
                    return !upper.contains("BLOB") && !upper.contains("BYTEA") && !upper.contains("BINARY")
                        && !upper.contains("VARBINARY") && !upper.contains("IMAGE")
                }
                query = SQLBuilder.buildSearchSelect(
                    table: table.name, type: connection.type,
                    searchText: activeSearchText, searchColumns: searchableColumns,
                    filters: filters, logicMode: filterLogicMode,
                    sortState: sortState,
                    limit: pagination.pageSize, offset: pagination.currentOffset
                )
            } else if hasActiveFilters {
                query = SQLBuilder.buildFilteredSelect(
                    table: table.name, type: connection.type,
                    filters: filters, logicMode: filterLogicMode,
                    sortState: sortState,
                    limit: pagination.pageSize, offset: pagination.currentOffset
                )
            } else if sortState.isSorting {
                query = SQLBuilder.buildSelect(
                    table: table.name, type: connection.type,
                    sortState: sortState,
                    limit: pagination.pageSize, offset: pagination.currentOffset
                )
            } else {
                query = SQLBuilder.buildSelect(
                    table: table.name, type: connection.type,
                    limit: pagination.pageSize, offset: pagination.currentOffset
                )
            }
            let result = try await session.driver.execute(query: query)
            columns = result.columns
            rows = result.rows
            if rows.count < pagination.pageSize, pagination.totalRows == nil {
                pagination.totalRows = pagination.currentOffset + rows.count
            }
            if columnDetails.isEmpty {
                columnDetails = try await session.driver.fetchColumns(table: table.name, schema: nil)
            }
            if foreignKeys.isEmpty {
                do {
                    foreignKeys = try await session.driver.fetchForeignKeys(table: table.name, schema: nil)
                } catch {
                    Self.logger.warning("Failed to fetch foreign keys: \(error.localizedDescription, privacy: .public)")
                }
            }
            if pagination.totalRows == nil {
                await fetchTotalRows(session: session)
            }
            isLoading = false
        } catch {
            appError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "loadData", databaseType: connection.type, host: connection.host)
            )
            isLoading = false
        }
    }

    private func fetchTotalRows(session: ConnectionSession) async {
        do {
            let countQuery: String
            if hasActiveSearch {
                let searchableColumns = columns.filter { col in
                    let upper = col.typeName.uppercased()
                    return !upper.contains("BLOB") && !upper.contains("BYTEA") && !upper.contains("BINARY")
                        && !upper.contains("VARBINARY") && !upper.contains("IMAGE")
                }
                countQuery = SQLBuilder.buildSearchCount(
                    table: table.name, type: connection.type,
                    searchText: activeSearchText, searchColumns: searchableColumns,
                    filters: filters, logicMode: filterLogicMode
                )
            } else if hasActiveFilters {
                countQuery = SQLBuilder.buildFilteredCount(
                    table: table.name, type: connection.type,
                    filters: filters, logicMode: filterLogicMode
                )
            } else {
                countQuery = SQLBuilder.buildCount(table: table.name, type: connection.type)
            }
            let countResult = try await session.driver.execute(query: countQuery)
            if let firstRow = countResult.rows.first, let firstCol = firstRow.first {
                pagination.totalRows = Int(firstCol ?? "0")
            }
        } catch {
            Self.logger.warning("Failed to fetch row count: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func changePageSize(_ newSize: Int) {
        pagination.pageSize = newSize
        pagination.currentPage = 0
        pagination.totalRows = nil
        Task { await navigatePage() }
    }

    private func goToPage() {
        guard let page = Int(goToPageInput), page >= 1 else { return }
        if let total = pagination.totalRows {
            let maxPage = max(1, (total + pagination.pageSize - 1) / pagination.pageSize)
            pagination.currentPage = min(page - 1, maxPage - 1)
        } else {
            pagination.currentPage = page - 1
        }
        Task { await navigatePage() }
    }

    private func goToNextPage() async {
        guard pagination.hasNextPage else { return }
        pagination.currentPage += 1
        await navigatePage()
    }

    private func goToPreviousPage() async {
        guard pagination.currentPage > 0 else { return }
        pagination.currentPage -= 1
        await navigatePage()
    }

    private func navigatePage() async {
        isPageLoading = true
        await loadData()
        rowListGeneration += 1
        isPageLoading = false
    }

    // MARK: - Row Operations

    private func deleteRow(withPKs pkValues: [(column: String, value: String)]) async {
        guard let session, !pkValues.isEmpty else { return }
        do {
            _ = try await session.driver.execute(
                query: SQLBuilder.buildDelete(table: table.name, type: connection.type, primaryKeys: pkValues)
            )
            await loadData()
            hapticSuccess.toggle()
        } catch {
            operationError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "deleteRow", databaseType: connection.type, host: connection.host)
            )
            showOperationError = true
            hapticError.toggle()
        }
    }

    private func primaryKeyValues(for row: [String?]) -> [(column: String, value: String)] {
        columnDetails.compactMap { col in
            guard col.isPrimaryKey,
                  let colIndex = columns.firstIndex(where: { $0.name == col.name }),
                  colIndex < row.count,
                  let value = row[colIndex] else { return nil }
            return (column: col.name, value: value)
        }
    }

    private func applySort() {
        pagination.currentPage = 0
        pagination.totalRows = nil
        Task { await loadData() }
    }

    private func applySearch() {
        activeSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasActiveSearch, !columns.isEmpty else { return }
        pagination.currentPage = 0
        pagination.totalRows = nil
        searchTask?.cancel()
        searchTask = Task { await loadData() }
    }

    private func clearSearch() {
        searchText = ""
        activeSearchText = ""
        pagination.currentPage = 0
        pagination.totalRows = nil
        searchTask?.cancel()
        searchTask = Task { await loadData() }
    }

    private func applyFilters() {
        pagination.currentPage = 0
        pagination.totalRows = nil
        Task { await loadData() }
    }

    private func clearFilters() {
        filters.removeAll()
        pagination.currentPage = 0
        pagination.totalRows = nil
        Task { await loadData() }
    }
}

// MARK: - Filter Sheet

private struct FilterSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: [TableFilter]
    @Binding var logicMode: FilterLogicMode
    let columns: [ColumnInfo]
    let onApply: () -> Void
    let onClear: () -> Void

    @State private var draft: [TableFilter] = []
    @State private var draftLogicMode: FilterLogicMode = .and

    private var hasValidFilters: Bool {
        draft.contains { $0.isEnabled && $0.isValid }
    }

    private func bindingForFilter(_ id: UUID) -> Binding<TableFilter>? {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return nil }
        return $draft[index]
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.count > 1 {
                    Section {
                        Picker("Logic", selection: $draftLogicMode) {
                            Text("AND").tag(FilterLogicMode.and)
                            Text("OR").tag(FilterLogicMode.or)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                ForEach(draft) { filter in
                    if let binding = bindingForFilter(filter.id) {
                        Section {
                            Picker("Column", selection: binding.columnName) {
                                ForEach(columns, id: \.name) { col in
                                    Text(col.name).tag(col.name)
                                }
                            }

                            Picker("Operator", selection: binding.filterOperator) {
                                ForEach(FilterOperator.allCases, id: \.self) { op in
                                    Text(op.displayName).tag(op)
                                }
                            }

                            if filter.filterOperator.needsValue {
                                TextField("Value", text: binding.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            if filter.filterOperator == .between {
                                TextField("Second value", text: binding.secondValue)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    draft.remove(atOffsets: indexSet)
                }

                Section {
                    Button {
                        draft.append(TableFilter(columnName: columns.first?.name ?? ""))
                    } label: {
                        Label("Add Filter", systemImage: "plus.circle")
                    }
                }

                if !draft.isEmpty {
                    Section {
                        Button("Clear All Filters", role: .destructive) {
                            filters.removeAll()
                            logicMode = .and
                            onClear()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filters = draft
                        logicMode = draftLogicMode
                        onApply()
                        dismiss()
                    }
                    .disabled(!hasValidFilters)
                }
            }
            .onAppear {
                draft = filters
                draftLogicMode = logicMode
            }
        }
    }
}

// MARK: - Filter Operator Display

extension FilterOperator {
    var displayName: String {
        switch self {
        case .equal: return "equals"
        case .notEqual: return "not equals"
        case .greaterThan: return "greater than"
        case .greaterThanOrEqual: return "≥"
        case .lessThan: return "less than"
        case .lessThanOrEqual: return "≤"
        case .like: return "like"
        case .notLike: return "not like"
        case .isNull: return "is null"
        case .isNotNull: return "is not null"
        case .in: return "in"
        case .notIn: return "not in"
        case .between: return "between"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        }
    }

    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull: return false
        default: return true
        }
    }
}

// MARK: - Row Card

private struct RowCard: View {
    let columns: [ColumnInfo]
    let columnDetails: [ColumnInfo]
    let row: [String?]

    private static let maxPreview = 4

    private var pkNames: Set<String> {
        Set(columnDetails.filter(\.isPrimaryKey).map(\.name))
    }

    private var titlePair: (name: String, value: String)? {
        let pks = pkNames
        for (col, val) in zip(columns, row) where pks.contains(col.name) {
            return (col.name, val ?? "NULL")
        }
        guard let first = columns.first else { return nil }
        return (first.name, row.first.flatMap { $0 } ?? "NULL")
    }

    private var detailPairs: [(name: String, value: String)] {
        let pks = pkNames
        let title = titlePair?.name
        return zip(columns, row)
            .filter { !pks.contains($0.0.name) && $0.0.name != title }
            .prefix(Self.maxPreview - 1)
            .map { ($0.0.name, $0.1 ?? "NULL") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = titlePair {
                HStack(spacing: 6) {
                    Text(title.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: title.value)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }

            ForEach(Array(detailPairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 6) {
                    Text(pair.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: pair.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if columns.count > Self.maxPreview {
                Text("+\(columns.count - Self.maxPreview) more columns")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
