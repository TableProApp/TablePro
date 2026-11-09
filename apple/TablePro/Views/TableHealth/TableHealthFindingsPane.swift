import SwiftUI

struct TableHealthFindingsPane: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseType: DatabaseType
    let actions: TableHealthActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHeader {
                header
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String? {
        guard let summary = viewModel.currentCheck?.check.summary, !summary.isEmpty else { return nil }
        return summary
    }

    // In All Findings with rows on screen; with none, the empty state says it instead.
    private var failedChecks: Int {
        guard viewModel.scope == .all, viewModel.listState == .rows else { return 0 }
        return viewModel.failedCheckCount
    }

    private var hasHeader: Bool {
        summary != nil || viewModel.checkFailure != nil || failedChecks > 0 || !viewModel.notes.isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary {
                Text(verbatim: summary)
            }
            if let failure = viewModel.checkFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
            }
            if failedChecks > 0 {
                Label {
                    Text(Self.failedChecksText(failedChecks))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            ForEach(viewModel.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.listState {
        case .rows:
            if viewModel.scope == .resolved {
                TableHealthResolvedTable(viewModel: viewModel)
            } else {
                TableHealthFindingsTable(viewModel: viewModel, databaseType: databaseType, actions: actions)
            }
        case .noFindings(let description):
            UnavailableStateView(
                String(localized: "No Findings"),
                systemImage: "checkmark.circle",
                description: description.isEmpty ? nil : Text(verbatim: description)
            )
        case .skipped(let reason):
            UnavailableStateView(
                String(localized: "Check Skipped"),
                systemImage: "info.circle",
                description: Text(verbatim: reason)
            )
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "Check Failed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await viewModel.refresh() }
                }
            }
        case .noResults:
            UnavailableStateView.search(text: viewModel.filterText)
        case .ignoredHidden(let count):
            UnavailableStateView {
                Label(String(localized: "No Findings"), systemImage: "eye.slash")
            } description: {
                Text("^[\(count) ignored finding](inflect: true) hidden.")
            } actions: {
                Button(String(localized: "Show Ignored")) { viewModel.showIgnored = true }
            }
        case .someChecksFailed(let count):
            UnavailableStateView {
                Label(String(localized: "Some Checks Failed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(Self.failedChecksText(count))
            }
        case .noResolved:
            UnavailableStateView(
                String(localized: "No Resolved Findings"),
                systemImage: "clock.arrow.circlepath",
                description: Text("A finding moves here when a refresh no longer reports it.")
            )
        }
    }

    private static func failedChecksText(_ count: Int) -> LocalizedStringKey {
        "^[\(count) check](inflect: true) could not run. Select one to see why."
    }
}
