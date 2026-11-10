import SwiftUI

struct TableHealthChecksList: View {
    // HIG, Offering help: a tooltip past about 75 characters stops being read. Longer text shows in the pane.
    private static let tooltipLimit = 75

    @ObservedObject var viewModel: TableHealthViewModel

    var body: some View {
        List(selection: scopeSelection) {
            Label(String(localized: "All Findings"), systemImage: "tray.full")
                .badge(viewModel.allFindingsCount)
                .tag(TableHealthScope.all)
            if let report = viewModel.report {
                Section(String(localized: "Checks")) {
                    ForEach(report.checks) { result in
                        Label(result.check.title, systemImage: result.check.systemImage)
                            .badge(badge(for: result))
                            .help(tooltip(for: result))
                            .tag(TableHealthScope.check(result.kind))
                    }
                }
            }
            Section(String(localized: "History")) {
                Label(String(localized: "Resolved"), systemImage: "clock.arrow.circlepath")
                    .badge(viewModel.resolvedCount)
                    .tag(TableHealthScope.resolved)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(String(localized: "Checks"))
        .contextMenu(forSelectionType: TableHealthScope.self) { scopes in
            if scopes.contains(.resolved), viewModel.resolvedCount > 0 {
                Button(String(localized: "Clear Resolved")) { viewModel.clearResolved() }
            }
        }
        // Without it Edit > Copy falls through to the window, which copies the sidebar's table names.
        .onCopyCommand {
            TableHealthCopy.providers(viewModel.selectionTSV())
        }
    }

    // A List cannot deselect into nothing here: some scope is always shown.
    private var scopeSelection: Binding<TableHealthScope?> {
        Binding(
            get: { viewModel.scope },
            set: { scope in
                guard let scope else { return }
                viewModel.scope = scope
            }
        )
    }

    private func badge(for result: TableHealthCheckResult) -> Text? {
        switch result.outcome {
        case .completed:
            let findings = viewModel.badgeCount(for: result.kind)
            return findings == 0 ? nil : Text(verbatim: findings.formatted())
        case .skipped:
            return Text("Skipped")
        case .failed:
            return Text("Failed")
        }
    }

    private func tooltip(for result: TableHealthCheckResult) -> String {
        let text: String
        switch result.outcome {
        case .completed: text = result.check.summary
        case .skipped(let reason): text = reason
        case .failed(let message): text = message
        }
        return text.count <= Self.tooltipLimit ? text : ""
    }
}
