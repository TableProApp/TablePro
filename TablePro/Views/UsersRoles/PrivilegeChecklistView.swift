import SwiftUI
import TableProPluginKit

struct PrivilegeChecklistView: View {
    @Bindable var viewModel: UsersRolesViewModel

    @State private var expansion: [String: Bool] = [:]

    private var hasEditableScope: Bool {
        viewModel.selection != nil
            && !viewModel.selectedScopes.isEmpty
            && !viewModel.isMixedScopeSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasEditableScope {
                header
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(scopeTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                bulkMenu
            }
            NativeSearchField(
                text: $viewModel.privilegeFilter,
                placeholder: String(localized: "Filter privileges")
            )
            .accessibilityIdentifier("usersroles-privilege-filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var scopeTitle: String {
        if viewModel.selectedScopes.isEmpty {
            return String(localized: "No Object Selected")
        }
        if let scope = viewModel.singleSelectedScope {
            return scope.displayPath
        }
        return String(
            format: String(localized: "%lld objects selected"),
            viewModel.selectedScopes.count
        )
    }

    private var bulkMenu: some View {
        Menu {
            Button(String(localized: "Grant All")) { setAll(true) }
            Button(String(localized: "Revoke All")) { setAll(false) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.privilegeSections.isEmpty)
        .help(String(localized: "Bulk actions"))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.selection == nil {
            ContentUnavailableView(
                String(localized: "No Selection"),
                systemImage: "person.2",
                description: Text("Select a user or role to view its privileges.")
            )
        } else if viewModel.isMixedScopeSelection {
            ContentUnavailableView(
                String(localized: "Mixed Selection"),
                systemImage: "square.stack.3d.up.slash",
                description: Text("Select objects of the same kind to edit their privileges.")
            )
        } else if viewModel.selectedScopes.isEmpty {
            ContentUnavailableView(
                String(localized: "No Object Selected"),
                systemImage: "hand.tap",
                description: Text("Select an object on the left to edit its privileges.")
            )
        } else if let error = viewModel.grantsError {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: String(localized: "Unable to Load Privileges"),
                description: error,
                actionTitle: String(localized: "Retry"),
                action: { Task { await reloadGrants() } }
            )
        } else if viewModel.privilegeSections.isEmpty {
            emptyPrivileges
        } else {
            table
        }
    }

    @ViewBuilder
    private var emptyPrivileges: some View {
        if !viewModel.privilegeFilter.isEmpty {
            ContentUnavailableView.search(text: viewModel.privilegeFilter)
        } else {
            ContentUnavailableView(
                String(localized: "No Privileges"),
                systemImage: "lock",
                description: Text("No privileges can be granted at this level.")
            )
        }
    }

    private var table: some View {
        Table(of: PrivilegeRow.self) {
            TableColumn(String(localized: "Granted")) { row in
                grantedCell(row)
            }
            .width(60)

            TableColumn(String(localized: "Privilege")) { row in
                privilegeCell(row)
            }
            .width(min: 140, ideal: 220)

            TableColumn(String(localized: "Effective")) { row in
                effectiveCell(row)
            }
            .width(min: 100, ideal: 180)
        } rows: {
            ForEach(viewModel.privilegeSections) { section in
                DisclosureTableRow(
                    section.headerRow,
                    isExpanded: expansionBinding(for: section)
                ) {
                    ForEach(section.rows) { SwiftUI.TableRow($0) }
                }
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .accessibilityIdentifier("usersroles-privilege-table")
    }

    // MARK: - Cells

    @ViewBuilder
    private func grantedCell(_ row: PrivilegeRow) -> some View {
        switch row.kind {
        case let .category(category):
            let section = viewModel.privilegeSections.first { $0.category == category }
            TristateCheckbox(
                state: section.map { viewModel.sectionState($0) } ?? .unchecked,
                accessibilityLabel: category.title,
                accessibilityValue: stateDescription(section.map { viewModel.sectionState($0) })
            ) {
                guard let section else { return }
                viewModel.setGranted(viewModel.sectionState(section) != .checked, section: section)
            }

        case let .privilege(descriptor):
            if viewModel.selectedScopes.count > 1 {
                TristateCheckbox(
                    state: viewModel.grantState(for: descriptor.name),
                    accessibilityLabel: descriptor.label,
                    accessibilityValue: stateDescription(viewModel.grantState(for: descriptor.name))
                ) {
                    viewModel.setGranted(
                        viewModel.grantState(for: descriptor.name) != .checked,
                        privilege: descriptor.name
                    )
                }
            } else {
                Toggle(
                    descriptor.label,
                    isOn: Binding(
                        get: { viewModel.grantState(for: descriptor.name) == .checked },
                        set: { viewModel.setGranted($0, privilege: descriptor.name) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func privilegeCell(_ row: PrivilegeRow) -> some View {
        HStack(spacing: 4) {
            Text(row.title)
                .fontWeight(isStaged(row) ? .semibold : .regular)
            if let descriptor = row.descriptor, viewModel.isGrantable(descriptor.name) {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
                    .help(String(localized: "This user can grant this privilege to others."))
                    .accessibilityLabel(String(localized: "Can grant to others"))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func effectiveCell(_ row: PrivilegeRow) -> some View {
        if let descriptor = row.descriptor {
            switch viewModel.effectiveness(for: descriptor.name) {
            case .direct, .notEffective:
                EmptyView()

            case let .viaScope(scope):
                Label(
                    String(format: String(localized: "Granted on %@"), scope.displayName),
                    systemImage: "arrow.turn.left.up"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            case let .viaRole(name, isAutomatic):
                Label(
                    String(format: String(localized: "Inherited from %@"), name),
                    systemImage: "person.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(
                    isAutomatic
                        ? String(localized: "Inherited automatically.")
                        : String(format: String(localized: "Available after SET ROLE %@."), name)
                )
            }
        }
    }

    // MARK: - Helpers

    private func isStaged(_ row: PrivilegeRow) -> Bool {
        guard let descriptor = row.descriptor,
              let principal = viewModel.selection,
              let scope = viewModel.singleSelectedScope else { return false }

        let delta = viewModel.changeManager.grantDeltas[principal]
        let key = PrincipalGrantKey(privilege: descriptor.name, scope: scope)
        return delta?.added.contains(key) == true || delta?.removed.contains(key) == true
    }

    private func stateDescription(_ state: TristateCheckbox.State?) -> String {
        switch state {
        case .checked: String(localized: "Granted")
        case .mixed: String(localized: "Partly granted")
        default: String(localized: "Not granted")
        }
    }

    private func expansionBinding(for section: PrivilegeSection) -> Binding<Bool> {
        Binding(
            get: { expansion[section.category.key] ?? !section.category.isCollapsedByDefault },
            set: { expansion[section.category.key] = $0 }
        )
    }

    private func setAll(_ isGranted: Bool) {
        let privileges = viewModel.privilegeSections
            .flatMap(\.rows)
            .compactMap(\.descriptor)
            .map(\.name)
        viewModel.setGranted(isGranted, privileges: privileges)
    }

    private func reloadGrants() async {
        guard let principal = viewModel.selection else { return }
        await viewModel.loadGrants(for: principal)
    }
}
