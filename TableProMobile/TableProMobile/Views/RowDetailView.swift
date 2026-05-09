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

    init(
        columns: [ColumnInfo],
        rows: [Row],
        initialIndex: Int,
        table: TableInfo? = nil,
        session: ConnectionSession? = nil,
        columnDetails: [ColumnInfo] = [],
        databaseType: DatabaseType = .sqlite,
        safeModeLevel: SafeModeLevel = .off,
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
                    ForEach(viewModel.rows.indices, id: \.self) { index in
                        rowContent(at: index)
                            .tag(index)
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
        .navigationTitle(viewModel.table?.name ?? String(format: String(localized: "Row %d of %d"), viewModel.currentIndex + 1, viewModel.rows.count))
        .navigationBarTitleDisplayMode(.inline)
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
    }

    @ToolbarContentBuilder
    private var rowDetailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                shareMenuContent
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if viewModel.canEdit {
                if viewModel.isEditing {
                    Button {
                        Task { await handleSave() }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(viewModel.isSaving)
                } else {
                    Button("Edit") { viewModel.startEditing() }
                }
            }
        }

        if viewModel.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { viewModel.cancelEditing() }
                    .disabled(viewModel.isSaving)
            }
        }

        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                viewModel.currentIndex -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(viewModel.currentIndex <= 0 || viewModel.isEditing)

            Spacer()

            Text("\(viewModel.currentIndex + 1) of \(viewModel.rows.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            Spacer()

            Button {
                viewModel.currentIndex += 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(viewModel.currentIndex >= viewModel.rows.count - 1 || viewModel.isEditing)
        }
    }

    @ViewBuilder
    private var shareMenuContent: some View {
        Section("Share") {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    shareText = ClipboardExporter.exportRow(
                        columns: viewModel.columns, row: viewModel.currentRow,
                        format: format, tableName: viewModel.table?.name
                    )
                    showShareSheet = true
                } label: {
                    Label(format.rawValue, systemImage: "square.and.arrow.up")
                }
            }
        }
        Section("Copy to Clipboard") {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    let text = ClipboardExporter.exportRow(
                        columns: viewModel.columns, row: viewModel.currentRow,
                        format: format, tableName: viewModel.table?.name
                    )
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
                Section {
                    if viewModel.isEditing && !isPK {
                        editableField(index: index, value: value)
                    } else {
                        fieldContent(value: value)
                            .contextMenu {
                                if let value {
                                    Button {
                                        UIPasteboard.general.string = value
                                    } label: {
                                        Label("Copy Value", systemImage: "doc.on.doc")
                                    }
                                }
                                Button {
                                    UIPasteboard.general.string = column.name
                                } label: {
                                    Label("Copy Column Name", systemImage: "textformat")
                                }
                            }
                        if index < cells.count, cells[index].isLoadable,
                           !viewModel.hasOverride(forRow: viewModel.currentIndex, cellIndex: index) {
                            lazyLoadButton(cell: cells[index], cellIndex: index)
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

                        if viewModel.isEditing && isPK {
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
    private func lazyLoadButton(cell: Cell, cellIndex: Int) -> some View {
        if let ref = cell.fullValueRef, viewModel.supportsLazyLoading {
            Button {
                Task { await viewModel.loadFullValue(ref: ref, cellIndex: cellIndex) }
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

        return HStack {
            if isNull {
                Text("NULL")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                TextField("Value", text: textBinding)
                    .font(.body)
            }

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

    @ViewBuilder
    private func fieldContent(value: String?) -> some View {
        if let value {
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
        if success {
            hapticSuccess.toggle()
        } else {
            hapticError.toggle()
        }
    }
}
