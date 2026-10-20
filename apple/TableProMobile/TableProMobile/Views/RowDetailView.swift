import SwiftUI
import TableProDatabase
import TableProModels

struct RowDetailView: View {
    @State private var viewModel: RowDetailViewModel
    @State private var fkPreviewItem: FKPreviewItem?
    @State private var showShareSheet = false
    @State private var shareText = ""
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var hapticSelection = 0
    @State private var showSaveConfirmation = false
    @State private var jsonEditorField: IndexedRow<String>?
    @State private var jsonViewerRoute: JSONValueViewer.Route?

    init(
        columns: [ColumnInfo],
        rows: [Row],
        initialIndex: Int,
        table: TableInfo? = nil,
        session: ConnectionSession? = nil,
        columnDetails: [ColumnInfo] = [],
        databaseType: DatabaseType = .sqlite,
        schema: String? = nil,
        safeModeLevel: @escaping () -> SafeModeLevel = { .off },
        foreignKeys: [ForeignKeyInfo] = [],
        onSaved: (() -> Void)? = nil,
        loadFullValue: ((CellRef) async throws -> String?)? = nil
    ) {
        _viewModel = State(wrappedValue: RowDetailViewModel(
            columns: columns,
            rows: rows,
            initialIndex: initialIndex,
            table: table,
            session: session,
            columnDetails: columnDetails,
            databaseType: databaseType,
            schema: schema,
            safeModeLevel: safeModeLevel,
            foreignKeys: foreignKeys,
            onSaved: onSaved,
            loadFullValue: loadFullValue
        ))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if viewModel.isEditing {
                rowContent(at: viewModel.currentIndex)
            } else {
                TabView(selection: $viewModel.currentIndex) {
                    ForEach(IndexedRow.wrap(viewModel.rows)) { item in
                        rowContent(at: item.id)
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: viewModel.currentIndex) {
            hapticSelection += 1
        }
        .overlay(alignment: .bottom) {
            if viewModel.showSaveSuccess {
                Label("Row updated", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .padding()
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .bottomSafeAreaBar {
            if viewModel.showsRowNavigator {
                rowNavigator
            }
        }
        .navigationBarBackButtonHidden(viewModel.isEditing)
        .holdsScene(withUnsavedChanges: viewModel.hasUnsavedEdits)
        .navigationTitle(viewModel.table?.name ?? String(format: String(localized: "Row %d of %d"), viewModel.currentIndex + 1, viewModel.rows.count))
        .navigationBarTitleDisplayMode(.inline)
        // A NavigationLink inside the paged TabView cannot reach the stack: it pushes a blank screen.
        .navigationDestination(item: $jsonViewerRoute) { route in
            JSONValueViewer(route: route)
        }
        .toolbar { rowDetailToolbar }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
        .sensoryFeedback(.selection, trigger: hapticSelection)
        .alert(
            viewModel.operationError?.title ?? "Error",
            isPresented: Binding(
                get: { viewModel.operationError != nil },
                set: { if !$0 { viewModel.operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let recovery = viewModel.operationError?.recovery {
                Text(verbatim: "\(viewModel.operationError?.message ?? "") \(recovery)")
            } else {
                Text(viewModel.operationError?.message ?? "")
            }
        }
        .alert("Save Changes?", isPresented: $showSaveConfirmation) {
            Button(String(localized: "Save"), role: .destructive) {
                Task { await executePendingSave() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "This will update a row in %@. Continue?"), viewModel.table?.name ?? ""))
        }
        .sheet(item: $fkPreviewItem) { item in
            FKPreviewView(
                fk: item.fk,
                value: item.value,
                session: viewModel.session,
                databaseType: viewModel.databaseType
            )
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(items: [shareText])
        }
        .sheet(item: $jsonEditorField) { field in
            JSONValueEditorSheet(title: viewModel.columns[field.id].name, text: field.values, onDone: { text in
                guard text != field.values else { return }
                viewModel.setEditedValue(text, at: field.id)
            })
        }
    }

    @ToolbarContentBuilder
    private var rowDetailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                shareMenuContent
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if viewModel.canEdit {
                if viewModel.isEditing {
                    ConfirmButton(title: "Save", isInProgress: viewModel.isSaving) {
                        Task { await handleSave() }
                    }
                    .disabled(viewModel.isSaving || viewModel.hasInvalidJSONEdit)
                } else {
                    Button { viewModel.startEditing() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
        }

        if viewModel.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                DiscardChangesCancelButton(hasChanges: viewModel.hasUnsavedEdits) {
                    viewModel.cancelEditing()
                }
                .disabled(viewModel.isSaving)
            }
        }
    }

    private var rowNavigator: some View {
        PagingBar(
            previousTitle: "Previous Row",
            nextTitle: "Next Row",
            canGoPrevious: viewModel.canGoToPreviousRow,
            canGoNext: viewModel.canGoToNextRow,
            onPrevious: viewModel.goToPreviousRow,
            onNext: viewModel.goToNextRow
        ) {
            Text("\(viewModel.currentIndex + 1) of \(viewModel.rows.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    @ViewBuilder
    private var shareMenuContent: some View {
        Section("Share") {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    guard let text = viewModel.exportCurrentRow(as: format) else {
                        hapticError.toggle()
                        return
                    }
                    shareText = text
                    showShareSheet = true
                } label: {
                    Label(format.rawValue, systemImage: "square.and.arrow.up")
                }
            }
        }
        Section("Copy to Clipboard") {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    guard let text = viewModel.exportCurrentRow(as: format) else {
                        hapticError.toggle()
                        return
                    }
                    ClipboardExporter.copyToClipboard(text)
                } label: {
                    Label(format.rawValue, systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(at rowIndex: Int) -> some View {
        let row = viewModel.row(at: rowIndex)
        let cells = viewModel.cells(at: rowIndex)
        let values = viewModel.isEditing ? viewModel.editedValues : row
        List {
            ForEach(0..<min(viewModel.columns.count, values.count), id: \.self) { index in
                let column = viewModel.columns[index]
                let value = values[index]
                let isPK = viewModel.isPrimaryKey(at: index)
                let takesEdits = viewModel.isEditing && viewModel.takesEdits(at: index)
                Section {
                    if takesEdits {
                        editableField(index: index, value: value)
                        if viewModel.isJSON(at: index) {
                            editJSONButton(index: index)
                        }
                    } else {
                        let jsonText = viewModel.jsonText(forRow: rowIndex, at: index)
                        fieldContent(value: value, jsonPreview: viewModel.isJSON(at: index) ? jsonText : nil)
                            .contextMenu {
                                if let value = viewModel.completeValue(forRow: rowIndex, at: index) {
                                    Button {
                                        ClipboardExporter.copyToClipboard(value)
                                    } label: {
                                        Label("Copy Value", systemImage: "doc.on.doc")
                                    }
                                }
                                Button {
                                    ClipboardExporter.copyToClipboard(column.name)
                                } label: {
                                    Label("Copy Column Name", systemImage: "textformat")
                                }
                            }
                        if let jsonText {
                            Button {
                                jsonViewerRoute = JSONValueViewer.Route(title: column.name, text: jsonText)
                            } label: {
                                Label("View as JSON", systemImage: "curlybraces")
                            }
                        }
                        if index < cells.count, cells[index].isLoadable,
                           !viewModel.hasOverride(forRow: rowIndex, cellIndex: index) {
                            lazyLoadButton(cell: cells[index], rowIndex: rowIndex, cellIndex: index)
                        }
                        if let fk = viewModel.foreignKeys.first(where: { $0.column == column.name }), let value {
                            Button {
                                fkPreviewItem = FKPreviewItem(fk: fk, value: value)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.footnote)
                                    Text("\(fk.referencedTable).\(fk.referencedColumn)")
                                        .font(.footnote)
                                }
                                .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        if isPK {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text(column.name)

                        if viewModel.isEditing && !takesEdits {
                            Text("read-only")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        MetadataBadge(column.typeName)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func lazyLoadButton(cell: Cell, rowIndex: Int, cellIndex: Int) -> some View {
        if let ref = cell.fullValueRef, viewModel.supportsLazyLoading {
            Button {
                Task { await viewModel.loadFullValue(ref: ref, forRow: rowIndex, cellIndex: cellIndex) }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.loadingCell == cellIndex {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.footnote)
                    }
                    Text("Load full value")
                        .font(.footnote)
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.loadingCell != nil)
        }
    }

    private func editableField(index: Int, value: String?) -> some View {
        let textBinding = Binding<String>(
            get: {
                guard index < viewModel.editedValues.count else { return "" }
                return viewModel.editedValues[index] ?? ""
            },
            set: { newValue in viewModel.setEditedValue(newValue, at: index) }
        )

        let isNull = index < viewModel.editedValues.count ? viewModel.editedValues[index] == nil : true
        let offersNull = viewModel.isNullable(at: index) || isNull

        return HStack {
            if isNull {
                Text("NULL")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
            } else if viewModel.isJSON(at: index) {
                if let value, !value.isEmpty {
                    JSONFieldPreview(text: value)
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                LiteralTextField("Value", text: textBinding)
            }

            if offersNull {
                Button {
                    viewModel.toggleNull(at: index)
                } label: {
                    Text("NULL")
                        .font(.caption2)
                        .foregroundStyle(isNull ? .white : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isNull ? Color.accentColor : Color(.systemFill))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func editJSONButton(index: Int) -> some View {
        Button {
            let text = index < viewModel.editedValues.count ? viewModel.editedValues[index] : nil
            jsonEditorField = IndexedRow(id: index, values: text ?? "")
        } label: {
            Label("Edit JSON", systemImage: "pencil")
        }
    }

    @ViewBuilder
    private func fieldContent(value: String?, jsonPreview: String? = nil) -> some View {
        if let jsonPreview {
            JSONFieldPreview(text: jsonPreview)
        } else if let value {
            Text(verbatim: value)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text(verbatim: "NULL")
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private func handleSave() async {
        let success = await viewModel.saveChanges()
        if viewModel.pendingWriteConfirmation {
            showSaveConfirmation = true
            return
        }
        if success {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }

    private func executePendingSave() async {
        let success = await viewModel.executePendingSave()
        if success {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }
}
