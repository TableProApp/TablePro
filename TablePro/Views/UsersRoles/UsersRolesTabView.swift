import Combine
import SwiftUI
import TableProPluginKit

struct UsersRolesTabView: View {
    @Bindable var viewModel: UsersRolesViewModel
    let coordinator: MainContentCoordinator?

    @State private var actions = UsersRolesActionHandler()

    var body: some View {
        VStack(spacing: 0) {
            AutosavingSplitView(
                autosaveName: "com.TablePro.usersRoles.mainSplit",
                primaryMinimum: 200,
                primaryMaximum: 520,
                secondaryMinimum: 560
            ) {
                PrincipalListPane(viewModel: viewModel)
            } secondary: {
                PrincipalDetailPane(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            PendingChangesBar(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.load() }
        .onReceive(AppCommands.shared.refreshPrincipals) { connectionId in
            guard connectionId == viewModel.connectionId else { return }
            Task { await viewModel.load(forceReload: true) }
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(sheet)
        }
        .alert(
            String(localized: "Action Failed"),
            isPresented: actionErrorBinding,
            presenting: viewModel.actionError
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) { viewModel.actionError = nil }
        } message: { message in
            Text(message)
        }
        .onAppear { install() }
        .onDisappear { teardown() }
        .onChange(of: viewModel.changeCount) { _, _ in
            coordinator?.toolbarState.hasPrincipalChanges = viewModel.hasChanges
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: UsersRolesViewModel.ActiveSheet) -> some View {
        switch sheet {
        case .create:
            CreatePrincipalSheet(viewModel: viewModel)

        case let .changePassword(ref):
            ChangePasswordSheet(viewModel: viewModel, principal: ref)

        case let .drop(prompt):
            DropPrincipalSheet(viewModel: viewModel, prompt: prompt)

        case let .roleMembership(ref):
            RoleMembershipSheet(viewModel: viewModel, principal: ref)

        case let .copyPrivileges(ref):
            CopyPrivilegesSheet(viewModel: viewModel, target: ref)

        case .review:
            SQLReviewSheet(
                isPresented: reviewBinding,
                statements: viewModel.previewSQL,
                databaseType: viewModel.databaseType,
                warning: viewModel.lockoutWarning,
                failure: viewModel.applyFailure,
                primaryAction: SQLReviewSheet.PrimaryAction(
                    title: String(localized: "Execute"),
                    isDestructive: viewModel.hasDestructiveStatements
                ) {
                    await viewModel.executePendingChanges()
                },
                onOpenInEditor: {
                    coordinator?.loadQueryIntoEditor(
                        viewModel.previewSQL
                            .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                            .joined(separator: "\n\n")
                    )
                    viewModel.activeSheet = nil
                }
            )
        }
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { viewModel.activeSheet?.id == "review" },
            set: { if !$0 { viewModel.activeSheet = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )
    }

    private func install() {
        actions.hasChanges = { viewModel.hasChanges }
        actions.canUndo = { viewModel.canUndo }
        actions.canRedo = { viewModel.canRedo }
        actions.undoMenuTitle = { viewModel.undoMenuTitle }
        actions.redoMenuTitle = { viewModel.redoMenuTitle }
        actions.undo = { viewModel.undo() }
        actions.redo = { viewModel.redo() }
        actions.addPrincipal = { viewModel.activeSheet = .create }
        actions.dropSelected = {
            Task { await viewModel.requestDrop(viewModel.selectedRefs) }
        }
        actions.discard = { viewModel.discardChanges() }
        actions.reviewAndApply = { viewModel.requestApply() }
        actions.previewSQL = { viewModel.requestApply() }
        actions.refresh = {
            Task { await viewModel.load(forceReload: true) }
        }
        coordinator?.usersRolesActions = actions
        coordinator?.toolbarState.hasPrincipalChanges = viewModel.hasChanges
    }

    private func teardown() {
        guard coordinator?.usersRolesActions === actions else { return }
        coordinator?.usersRolesActions = nil
        coordinator?.toolbarState.hasPrincipalChanges = false
    }
}
