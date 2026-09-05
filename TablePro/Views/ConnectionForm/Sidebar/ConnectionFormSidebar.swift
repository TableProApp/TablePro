//
//  ConnectionFormSidebar.swift
//  TablePro
//

import SwiftUI

/// The editor's section list.
///
/// Follows the app's own `NavigationSplitView` pattern (`IntegrationsActivityView`): a
/// `List(selection:)` of `Label` rows at `.listStyle(.sidebar)`, with the column width declared on
/// the sidebar rather than the detail.
///
/// The badge is the part the old eleven-pane sidebar got wrong. It showed the same red triangle with
/// no text anywhere in the window, so a dimmed Save had no explanation. The strings existed the
/// whole time; `ConnectionFormTab.validationIssues(for:)` returns them, and the action bar spells
/// out the first one.
struct ConnectionFormSidebar: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        List(selection: $coordinator.selectedTab) {
            ForEach(coordinator.visibleTabs) { tab in
                row(for: tab)
                    .tag(tab)
                    .accessibilityIdentifier("connection-form-section-\(tab.rawValue)")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    @ViewBuilder
    private func row(for tab: ConnectionFormTab) -> some View {
        let issues = tab.validationIssues(for: coordinator)
        Label {
            HStack(spacing: 6) {
                Text(tab.title)
                Spacer(minLength: 4)
                if let first = issues.first {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help(issues.joined(separator: "\n"))
                        .accessibilityLabel(first)
                }
            }
        } icon: {
            Image(systemName: tab.systemImage)
        }
    }
}
