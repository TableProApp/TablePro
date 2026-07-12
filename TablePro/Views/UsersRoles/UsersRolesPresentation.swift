import SwiftUI
import TableProPluginKit

struct UsersRolesPresentation: ViewModifier {
    @Bindable var viewModel: UsersRolesViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.isCreateSheetPresented) { createSheet }
            .sheet(isPresented: $viewModel.isPasswordSheetPresented) { passwordSheet }
            .sheet(isPresented: $viewModel.isReviewPresented) { reviewSheet }
            .alert(
                dropAlertTitle,
                isPresented: isDropAlertPresented,
                presenting: viewModel.principalPendingDrop
            ) { _ in
                Button("Drop", role: .destructive) {
                    viewModel.confirmDrop(.plain)
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelDrop()
                }
            } message: { _ in
                Text("The statement is shown for review before it runs.")
            }
            .confirmationDialog(
                ownedObjectsTitle,
                isPresented: $viewModel.isOwnedObjectDialogPresented,
                titleVisibility: .visible
            ) {
                ownedObjectsActions
            } message: {
                Text("This role owns objects in the database. Choose what happens to them.")
            }
    }

    // MARK: - Sheets

    private var createSheet: some View {
        CreatePrincipalSheet(
            supportsHostScoping: viewModel.capabilities.hostScoping,
            supportsRoleMembership: viewModel.capabilities.roleMembership,
            availableRoles: viewModel.assignableRoles,
            onCreate: { viewModel.createPrincipal($0) }
        )
    }

    @ViewBuilder
    private var passwordSheet: some View {
        if let principal = viewModel.selectedPrincipal {
            ChangePasswordSheet(principal: principal.ref) { password in
                viewModel.setPassword(password, for: principal.ref)
            }
        }
    }

    private var reviewSheet: some View {
        PrincipalChangeReviewSheet(
            statements: viewModel.previewStatements,
            lockoutWarning: viewModel.lockoutWarning,
            onExecute: {
                Task { await viewModel.executePendingChanges() }
            }
        )
    }

    // MARK: - Drop

    private var isDropAlertPresented: Binding<Bool> {
        Binding(
            get: {
                viewModel.principalPendingDrop != nil && !viewModel.isOwnedObjectDialogPresented
            },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.cancelDrop()
            }
        )
    }

    private var dropAlertTitle: String {
        guard let principal = viewModel.principalPendingDrop else {
            return String(localized: "Drop")
        }
        return String(
            format: String(localized: "Are you sure you want to drop “%@”?"),
            principal.ref.displayName
        )
    }

    private var ownedObjectsTitle: String {
        guard let principal = viewModel.principalPendingDrop else {
            return String(localized: "Drop Role")
        }
        return String(
            format: String(localized: "“%@” owns database objects"),
            principal.ref.displayName
        )
    }

    @ViewBuilder
    private var ownedObjectsActions: some View {
        ForEach(viewModel.reassignCandidates, id: \.self) { candidate in
            Button(
                String(
                    format: String(localized: "Reassign objects to %@"),
                    candidate.displayName
                )
            ) {
                viewModel.confirmDrop(.reassignOwned(to: candidate))
            }
        }
        Button("Drop Owned Objects", role: .destructive) {
            viewModel.confirmDrop(.dropOwned)
        }
        Button("Cancel", role: .cancel) {
            viewModel.cancelDrop()
        }
    }
}
