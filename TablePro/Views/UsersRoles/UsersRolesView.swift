import Combine
import SwiftUI
import TableProPluginKit

struct UsersRolesView: View {
    @Bindable var viewModel: UsersRolesViewModel

    @State private var isInspectorPresented = true
    @State private var reassignTarget: PluginPrincipalRef?

    private var changeManager: PrincipalChangeManager { viewModel.changeManager }

    var body: some View {
        principalList
            .inspector(isPresented: $isInspectorPresented) {
                inspectorContent
                    .inspectorColumnWidth(min: 360, ideal: 460, max: 720)
            }
            .toolbar { toolbarContent }
            .task { await viewModel.load() }
            .onReceive(AppCommands.shared.refreshPrincipals) { connectionId in
                guard connectionId == viewModel.connectionId else { return }
                Task { await viewModel.load(forceReload: true) }
            }
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
                    viewModel.principalPendingDrop = nil
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
            .overlay { statusOverlay }
    }

    // MARK: - List

    private var principalList: some View {
        List(selection: selectionBinding) {
            ForEach(changeManager.principals, id: \.ref) { principal in
                principalRow(principal)
                    .tag(principal.ref)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: PluginPrincipalRef.self) { refs in
            if let ref = refs.first, let principal = principal(for: ref) {
                Button("Change Password…") {
                    Task {
                        await viewModel.select(ref)
                        viewModel.isPasswordSheetPresented = true
                    }
                }
                Button("Drop…", role: .destructive) {
                    Task { await viewModel.requestDrop(principal) }
                }
            }
        }
    }

    private func principal(for ref: PluginPrincipalRef) -> PluginPrincipalInfo? {
        changeManager.principals.first { $0.ref == ref }
    }

    private func principalRow(_ principal: PluginPrincipalInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: principal.canLogin ? "person.fill" : "person.2.fill")
                .foregroundStyle(.secondary)
            Text(principal.ref.displayName)
                .strikethrough(changeManager.pendingDrops[principal.ref] != nil)
            Spacer(minLength: 0)
            if changeManager.pendingDrops[principal.ref] != nil {
                Text("Drop")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        if let principal = viewModel.selectedPrincipal {
            PrincipalInspectorView(viewModel: viewModel, principal: principal)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "person.2",
                description: Text("Select a user or role to see its privileges.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                viewModel.isCreateSheetPresented = true
            } label: {
                Label("New User or Role", systemImage: "plus")
            }

            Button {
                guard let principal = viewModel.selectedPrincipal else { return }
                Task { await viewModel.requestDrop(principal) }
            } label: {
                Label("Drop", systemImage: "minus")
            }
            .disabled(viewModel.selectedPrincipal == nil)

            Spacer()

            Button("Discard") {
                viewModel.discardChanges()
            }
            .disabled(!changeManager.hasChanges)

            Button("Review SQL…") {
                viewModel.requestApply()
            }
            .disabled(!changeManager.canCommit)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private var createSheet: some View {
        CreatePrincipalSheet(
            supportsHostScoping: viewModel.supportsHostScoping,
            supportsRoleMembership: viewModel.supportsRoleMembership,
            availableRoles: changeManager.principals.filter(\.isRole).map(\.ref.name),
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

    @ViewBuilder
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
                viewModel.principalPendingDrop = nil
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
        ForEach(reassignCandidates, id: \.self) { candidate in
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
            viewModel.principalPendingDrop = nil
        }
    }

    private var reassignCandidates: [PluginPrincipalRef] {
        guard let pending = viewModel.principalPendingDrop else { return [] }
        guard let connected = viewModel.connectedPrincipal, connected != pending.ref else { return [] }
        return [connected]
    }

    // MARK: - Status

    @ViewBuilder
    private var statusOverlay: some View {
        if viewModel.isLoading, changeManager.principals.isEmpty {
            ProgressView()
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView(
                "Unable to Load Users and Roles",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        }
    }

    private var selectionBinding: Binding<PluginPrincipalRef?> {
        Binding(
            get: { viewModel.selection },
            set: { newValue in
                Task { await viewModel.select(newValue) }
            }
        )
    }
}
