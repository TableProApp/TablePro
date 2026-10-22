import SwiftUI
import TableProDatabase
import TableProModels

struct ForeignKeyPreviewPage: View {
    let currentSchema: String?
    let allowsOpen: Bool
    let refreshTransaction: () async -> Void
    let onOpen: ((ForeignKeyReference) -> Void)?
    let close: () -> Void

    @State private var model: ForeignKeyPreviewModel

    init(
        reference: ForeignKeyReference,
        session: ConnectionSession?,
        databaseType: DatabaseType,
        currentSchema: String?,
        allowsOpen: Bool,
        refreshTransaction: @escaping () async -> Void,
        onOpen: ((ForeignKeyReference) -> Void)?,
        close: @escaping () -> Void
    ) {
        self.currentSchema = currentSchema
        self.allowsOpen = allowsOpen
        self.refreshTransaction = refreshTransaction
        self.onOpen = onOpen
        self.close = close
        _model = State(initialValue: ForeignKeyPreviewModel(
            reference: reference,
            session: session,
            databaseType: databaseType
        ))
    }

    private var reference: ForeignKeyReference { model.reference }

    var body: some View {
        content
            .tableTitle(reference.table, schema: reference.displaySchema(current: currentSchema))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                await model.load()
                // With autocommit off, a MySQL read opens a transaction.
                await refreshTransaction()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List {
                ForEach(model.fields) { field in
                    fieldRow(field)
                }
            }
            .listStyle(.insetGrouped)
        case .notFound:
            ContentUnavailableView(
                "No Referenced Row",
                systemImage: "arrow.right.circle",
                description: Text(verbatim: model.notFoundMessage)
            )
        case .failed(let error):
            ErrorView(error: error)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            CloseButton(action: close)
        }
        if let onOpen {
            ToolbarItem(placement: .bottomBar) {
                // A toolbar draws a Label as its icon alone from iOS 26, and an arrow does not say what opens.
                Button("Open Table") {
                    onOpen(reference)
                }
                .disabled(!allowsOpen || !model.canOpen)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: ForeignKeyPreviewModel.Field) -> some View {
        if let next = field.reference, let value = field.value {
            NavigationLink(value: next) {
                LabeledContent {
                    Text(verbatim: value)
                } label: {
                    Text(verbatim: field.name)
                    Text(verbatim: next.table)
                }
            }
            .contextMenu {
                Button {
                    ClipboardExporter.copyToClipboard(value)
                } label: {
                    Label("Copy Value", systemImage: "doc.on.doc")
                }
            }
        } else {
            LabeledContent {
                Text(verbatim: field.value ?? "NULL")
                    .foregroundStyle(field.value == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            } label: {
                Text(verbatim: field.name)
            }
        }
    }
}
