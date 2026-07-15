import SwiftUI
import TableProPluginKit

struct PrivilegeEditorPane: View {
    @Bindable var viewModel: UsersRolesViewModel

    var body: some View {
        AutosavingSplitView(
            autosaveName: "com.TablePro.usersRoles.privilegeSplit",
            primaryMinimum: UsersRolesLayoutMetrics.privilegeScopeMinimumWidth,
            primaryMaximum: UsersRolesLayoutMetrics.privilegeScopeMaximumWidth,
            secondaryMinimum: UsersRolesLayoutMetrics.privilegeChecklistMinimumWidth
        ) {
            scopePane
        } secondary: {
            PrivilegeChecklistView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scopePane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                NativeSearchField(
                    text: $viewModel.scopeFilter,
                    placeholder: String(localized: "Filter objects")
                )
                .accessibilityIdentifier("usersroles-scope-filter")

                Picker("", selection: $viewModel.scopeMode) {
                    ForEach(UsersRolesViewModel.ScopeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("usersroles-scope-mode")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            PrivilegeScopeOutlineView(
                viewModel: viewModel,
                structureVersion: viewModel.privilegeTree.structureVersion,
                grantVersion: viewModel.changeManager.grantClosureVersion,
                principal: viewModel.selection
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: viewModel.scopeMode) { _, _ in
            viewModel.applyScopeMode()
        }
        .onChange(of: viewModel.scopeFilter) { _, _ in
            viewModel.searchScopes()
        }
        .onChange(of: viewModel.selection) { _, _ in
            if viewModel.scopeMode == .granted {
                viewModel.applyScopeMode()
            }
        }
    }
}
