import SwiftUI
import TableProDatabase
import TableProModels

struct FKPreviewItem: Identifiable {
    let id = UUID()
    let reference: ForeignKeyReference
}

struct FKPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let reference: ForeignKeyReference
    let session: ConnectionSession?
    let databaseType: DatabaseType
    let currentSchema: String?
    let allowsOpen: Bool
    let refreshTransaction: () async -> Void
    let onOpen: ((ForeignKeyReference) -> Void)?

    init(
        reference: ForeignKeyReference,
        session: ConnectionSession?,
        databaseType: DatabaseType,
        currentSchema: String? = nil,
        allowsOpen: Bool = true,
        refreshTransaction: @escaping () async -> Void,
        onOpen: ((ForeignKeyReference) -> Void)? = nil
    ) {
        self.reference = reference
        self.session = session
        self.databaseType = databaseType
        self.currentSchema = currentSchema
        self.allowsOpen = allowsOpen
        self.refreshTransaction = refreshTransaction
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            page(for: reference)
                .navigationDestination(for: ForeignKeyReference.self) { next in
                    page(for: next)
                }
        }
    }

    // A pushed page's own dismiss pops it, so every page closes the sheet through this view's.
    private func page(for reference: ForeignKeyReference) -> some View {
        ForeignKeyPreviewPage(
            reference: reference,
            session: session,
            databaseType: databaseType,
            currentSchema: currentSchema,
            allowsOpen: allowsOpen,
            refreshTransaction: refreshTransaction,
            onOpen: openAndClose,
            close: { dismiss() }
        )
    }

    private var openAndClose: ((ForeignKeyReference) -> Void)? {
        guard let onOpen else { return nil }
        return { reference in
            onOpen(reference)
            dismiss()
        }
    }
}
