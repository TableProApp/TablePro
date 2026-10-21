import SwiftUI
import TableProDatabase
import TableProModels

extension View {
    func foreignKeyPreview(
        item: Binding<FKPreviewItem?>,
        session: ConnectionSession?,
        coordinator: ConnectionCoordinator?,
        databaseType: DatabaseType,
        allowsOpen: Bool
    ) -> some View {
        modifier(ForeignKeyPreviewModifier(
            item: item,
            session: session,
            coordinator: coordinator,
            databaseType: databaseType,
            allowsOpen: allowsOpen
        ))
    }
}

private struct ForeignKeyPreviewModifier: ViewModifier {
    // The window's session coordinator; `coordinator` is set only where a referenced table can be opened.
    @Environment(ConnectionCoordinator.self) private var sessionCoordinator
    @Binding var item: FKPreviewItem?
    let session: ConnectionSession?
    let coordinator: ConnectionCoordinator?
    let databaseType: DatabaseType
    let allowsOpen: Bool

    @State private var requestedOpen: ForeignKeyReference?
    @State private var openedReference: ForeignKeyReference?

    private var currentSchema: String? {
        guard let coordinator, coordinator.supportsSchemas else { return nil }
        return coordinator.activeSchema
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $item, onDismiss: pushRequestedOpen) { presented in
                FKPreviewView(
                    reference: presented.reference,
                    session: session,
                    databaseType: databaseType,
                    currentSchema: currentSchema,
                    allowsOpen: allowsOpen && coordinator != nil,
                    refreshTransaction: { [sessionCoordinator] in await sessionCoordinator.refreshTransaction() },
                    onOpen: { requestedOpen = $0 }
                )
            }
            .navigationDestination(item: $openedReference) { reference in
                if let coordinator {
                    DataBrowserView(
                        table: reference.catalogTable(in: coordinator.tables, currentSchema: currentSchema),
                        reference: reference
                    )
                    .environment(coordinator)
                    .transactionBar(for: coordinator)
                }
            }
    }

    // A swipe-down also ends here, and only a stored Open Table request pushes, after the sheet is gone.
    private func pushRequestedOpen() {
        guard let reference = requestedOpen else { return }
        requestedOpen = nil
        openedReference = reference
    }
}
