import SwiftUI

struct TableHealthChecksList: View {
    // HIG, Offering help: a tooltip past about 75 characters stops being read. Longer text shows in the pane.
    private static let tooltipLimit = 75

    @ObservedObject var viewModel: TableHealthViewModel

    var body: some View {
        TableHealthChecksOutline(
            sections: sections,
            scope: $viewModel.scope,
            menu: { scope in TableHealthRowMenu.checks(scope: scope, resolvedCount: viewModel.resolvedCount) },
            perform: { command in
                if command == .clearResolved {
                    viewModel.clearResolved()
                }
            },
            copyText: { viewModel.selectionTSV() }
        )
    }

    private var sections: [TableHealthChecksSection] {
        var sections = [
            TableHealthChecksSection(title: nil, rows: [
                TableHealthChecksRow(
                    scope: .all,
                    title: String(localized: "All Findings"),
                    systemImage: "tray.full",
                    badge: Self.count(viewModel.allFindingsCount),
                    toolTip: nil
                ),
            ]),
        ]
        if let report = viewModel.report {
            sections.append(TableHealthChecksSection(
                title: String(localized: "Checks"),
                rows: report.checks.map { result in
                    TableHealthChecksRow(
                        scope: .check(result.kind),
                        title: result.check.title,
                        systemImage: result.check.systemImage,
                        badge: badge(for: result),
                        toolTip: tooltip(for: result)
                    )
                }
            ))
        }
        sections.append(TableHealthChecksSection(title: String(localized: "History"), rows: [
            TableHealthChecksRow(
                scope: .resolved,
                title: String(localized: "Resolved"),
                systemImage: "clock.arrow.circlepath",
                badge: Self.count(viewModel.resolvedCount),
                toolTip: nil
            ),
        ]))
        return sections
    }

    private static func count(_ value: Int) -> String? {
        value == 0 ? nil : value.formatted()
    }

    private func badge(for result: TableHealthCheckResult) -> String? {
        switch result.outcome {
        case .completed:
            return Self.count(viewModel.badgeCount(for: result.kind))
        case .skipped:
            return String(localized: "Skipped")
        case .failed:
            return String(localized: "Failed")
        }
    }

    private func tooltip(for result: TableHealthCheckResult) -> String? {
        let text: String
        switch result.outcome {
        case .completed: text = result.check.summary
        case .skipped(let reason): text = reason
        case .failed(let message): text = message
        }
        return text.isEmpty || text.count > Self.tooltipLimit ? nil : text
    }
}
