import Combine
import SwiftUI
import TableProPluginKit

struct UsersRolesView: View {
    @Bindable var viewModel: UsersRolesViewModel

    @State private var isInspectorPresented = true

    var changeManager: PrincipalChangeManager { viewModel.changeManager }

    var body: some View {
        principalList
            .inspector(isPresented: $isInspectorPresented) {
                inspector
                    .inspectorColumnWidth(min: 380, ideal: 520, max: 900)
            }
            .toolbar { toolbarContent }
            .task { await viewModel.load() }
            .onReceive(AppCommands.shared.refreshPrincipals) { connectionId in
                guard connectionId == viewModel.connectionId else { return }
                Task { await viewModel.load(forceReload: true) }
            }
            .modifier(UsersRolesPresentation(viewModel: viewModel))
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
            rowMenu(for: refs)
        }
    }

    private func principalRow(_ principal: PluginPrincipalInfo) -> some View {
        let isDropped = changeManager.pendingDrops[principal.ref] != nil

        return HStack(spacing: 6) {
            Image(systemName: principal.canLogin ? "person.fill" : "person.2.fill")
                .foregroundStyle(.secondary)
            Text(principal.ref.displayName)
                .strikethrough(isDropped)
            Spacer(minLength: 0)
            if isDropped {
                Text("Drop")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for refs: Set<PluginPrincipalRef>) -> some View {
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

    private func principal(for ref: PluginPrincipalRef) -> PluginPrincipalInfo? {
        changeManager.principals.first { $0.ref == ref }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
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

    // MARK: - Status

    @ViewBuilder
    private var statusOverlay: some View {
        if viewModel.isLoading, changeManager.principals.isEmpty {
            ProgressView()
        } else if let errorMessage = viewModel.errorMessage, changeManager.principals.isEmpty {
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
