import SwiftUI

struct TableHealthPaneBar: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseName: String
    let databaseType: DatabaseType
    let actions: TableHealthActions

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: databaseName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, alignment: .leading)
            if viewModel.report != nil, let error = viewModel.loadError {
                warning(error)
            }
            if let error = viewModel.storeError {
                warning(String(format: String(localized: "Could not update the finding history. %@"), error))
            }

            Spacer(minLength: 8)

            NativeSearchField(
                text: $viewModel.filterText,
                placeholder: String(localized: "Filter"),
                controlSize: .small,
                accessibilityIdentifier: "table-health-filter"
            )
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 180)
            Toggle(String(localized: "Show Ignored"), isOn: $viewModel.showIgnored)
                .toggleStyle(.checkbox)
            Button(String(localized: "Export…")) { actions.export() }
                .disabled(!viewModel.hasExportableRows)
            Button(String(localized: "Save Fix Script…")) {
                if let script = viewModel.fixScript(for: viewModel.shownFindings, databaseType: databaseType) {
                    actions.saveFixScript(script)
                }
            }
            .disabled(!viewModel.shownFindings.contains(where: TableHealthViewModel.hasFix))
            PaneRefreshControls(
                isRefreshing: viewModel.isRefreshing,
                lastRefreshDate: viewModel.lastRefreshDate,
                accessibilityIdentifier: "table-health-refresh-button"
            ) {
                Task { await viewModel.refresh() }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func warning(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .help(message)
            .accessibilityLabel(message)
    }
}
