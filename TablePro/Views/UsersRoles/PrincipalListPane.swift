import SwiftUI
import TableProPluginKit

struct PrincipalListPane: View {
    @Bindable var viewModel: UsersRolesViewModel

    @State private var sortOrder = [KeyPathComparator(\PrincipalRow.sortName)]

    private var rows: [PrincipalRow] {
        viewModel.principalRows.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                NativeSearchField(
                    text: $viewModel.principalFilter,
                    placeholder: String(localized: "Filter")
                )
                .accessibilityIdentifier("usersroles-principal-filter")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    AddRemoveControlGroup(
                        addLabel: String(localized: "New User or Role"),
                        removeLabel: String(localized: "Drop"),
                        canRemove: !viewModel.selectedRefs.isEmpty && !viewModel.isResolvingDrop,
                        addIdentifier: "usersroles-add",
                        removeIdentifier: "usersroles-remove",
                        onAdd: { viewModel.activeSheet = .create },
                        onRemove: { Task { await viewModel.requestDrop(viewModel.selectedRefs) } }
                    )
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.principalRows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.loadError {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: String(localized: "Unable to Load Users and Roles"),
                description: error,
                actionTitle: String(localized: "Retry"),
                action: { Task { await viewModel.load(forceReload: true) } }
            )
        } else if rows.isEmpty, !viewModel.principalFilter.isEmpty {
            ContentUnavailableView.search(text: viewModel.principalFilter)
        } else if rows.isEmpty {
            EmptyStateView(
                icon: "person.2",
                title: String(localized: "No Users or Roles"),
                description: String(localized: "This server has no users or roles you can manage."),
                actionTitle: String(localized: "New User or Role"),
                action: { viewModel.activeSheet = .create }
            )
        } else {
            table
        }
    }

    private var table: some View {
        principalTable
            .tableStyle(.inset)
            .alternatingRowBackgrounds(.enabled)
            .accessibilityIdentifier("usersroles-principal-list")
            .contextMenu(forSelectionType: PluginPrincipalRef.self) { refs in
                rowMenu(refs)
            }
            .onDeleteCommand {
                Task { await viewModel.requestDrop(viewModel.selectedRefs) }
            }
            .onChange(of: viewModel.selectedRefs) { _, refs in
                viewModel.selection = refs.count == 1 ? refs.first : nil
            }
            .task(id: viewModel.selection) {
                guard let selection = viewModel.selection else { return }
                await viewModel.loadGrants(for: selection)
            }
    }

    private var principalTable: some View {
        Table(rows, selection: $viewModel.selectedRefs, sortOrder: $sortOrder) {
            TableColumn(String(localized: "Name"), value: \PrincipalRow.sortName) { row in
                nameCell(row)
            }

            TableColumn(String(localized: "Kind")) { (row: PrincipalRow) in
                kindCell(row)
            }
            .width(min: 44, ideal: 52, max: 64)
        }
    }

    @ViewBuilder
    private func kindCell(_ row: PrincipalRow) -> some View {
        if viewModel.capabilities.roleMembership {
            Text(row.kindTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func nameCell(_ row: PrincipalRow) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Label(row.displayName, systemImage: row.symbolName)
                    .strikethrough(row.stage == .dropped)
                    .foregroundStyle(row.stage == .dropped ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !row.attributeSummary.isEmpty {
                    Text(row.attributeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
            statusGlyph(row)
        }
    }

    @ViewBuilder
    private func statusGlyph(_ row: PrincipalRow) -> some View {
        if let symbol = row.statusSymbol, let description = row.statusDescription {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .help(description)
                .accessibilityLabel(description)
        }
    }

    @ViewBuilder
    private func rowMenu(_ refs: Set<PluginPrincipalRef>) -> some View {
        if let ref = refs.first {
            Button(String(localized: "Change Password…")) {
                viewModel.activeSheet = .changePassword(ref)
            }
            Button(String(localized: "Copy Privileges From…")) {
                viewModel.activeSheet = .copyPrivileges(ref)
            }
            Button(String(localized: "Copy Name")) {
                ClipboardService.shared.writeText(ref.displayName)
            }
            Divider()
            if viewModel.changeManager.stage(of: ref) == .dropped {
                Button(String(localized: "Undo Staged Drop")) {
                    viewModel.undoStagedDrop(ref)
                }
            }
            Button(String(localized: "Drop…"), role: .destructive) {
                Task { await viewModel.requestDrop(refs) }
            }
        }
    }
}
