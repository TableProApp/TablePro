//
//  VersionHistoryListPane.swift
//  TablePro
//

import SwiftUI

internal struct VersionHistoryListPane: View {
    @ObservedObject var viewModel: VersionHistoryViewModel

    var body: some View {
        FieldDrivenList(
            sections: [FieldDrivenListSection(id: "versions", items: viewModel.page.entries)],
            selection: selectionBinding,
            rowHeight: 44,
            menuItems: { ids in menuItems(for: ids) },
            acceptsFocus: true,
            accessibilityIdentifier: "version-history-list",
            row: { entry in VersionHistoryRowView(entry: entry) }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = viewModel.page.notice {
                VStack(spacing: 0) {
                    Divider()
                    Text(VersionHistoryFormatting.noticeText(notice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var selectionBinding: Binding<Set<VersionHistoryReference>> {
        Binding(
            get: { viewModel.selection.map { [$0] } ?? [] },
            set: { viewModel.selection = $0.first }
        )
    }

    private func menuItems(for ids: Set<VersionHistoryReference>) -> [FieldDrivenMenuItem] {
        guard let id = ids.first,
              let entry = viewModel.page.entries.first(where: { $0.reference == id }),
              !entry.isCurrent
        else { return [] }
        return [
            FieldDrivenMenuItem(
                title: String(localized: "Restore This Version"),
                isEnabled: !viewModel.isRestoring
            ) {
                restore(entry)
            }
        ]
    }

    private func restore(_ entry: VersionHistoryEntry) {
        Task { await viewModel.restore(entry) }
    }
}
