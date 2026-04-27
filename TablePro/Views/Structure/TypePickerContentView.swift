//
//  TypePickerContentView.swift
//  TablePro
//
//  Searchable type picker for structure view column type editing.
//

import SwiftUI

struct TypePickerContentView: View {
    let databaseType: DatabaseType
    let currentValue: String
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private static let rowHeight: CGFloat = 22
    private static let sectionHeaderHeight: CGFloat = 28
    private static let searchAreaHeight: CGFloat = 44
    private static let maxTotalHeight: CGFloat = 360

    private var allCategories: [(name: String, types: [String])] {
        PluginManager.shared.columnTypesByCategory(for: databaseType)
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, types: $0.value) }
    }

    private var visibleCategories: [(name: String, types: [String])] {
        allCategories.compactMap { category in
            let filtered = filteredTypes(from: category.types)
            return filtered.isEmpty ? nil : (name: category.name, types: filtered)
        }
    }

    private func filteredTypes(from types: [String]) -> [String] {
        if searchText.isEmpty { return types }
        let query = searchText.lowercased()
        return types.filter { $0.lowercased().contains(query) }
    }

    private var totalFilteredCount: Int {
        visibleCategories.reduce(0) { $0 + $1.types.count }
    }

    private var listHeight: CGFloat {
        let contentHeight = CGFloat(totalFilteredCount) * Self.rowHeight
            + CGFloat(visibleCategories.count) * Self.sectionHeaderHeight
            + 8
        return min(contentHeight, Self.maxTotalHeight - Self.searchAreaHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search or type...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .onSubmit { commitFreeform() }

            Divider()

            List {
                ForEach(visibleCategories, id: \.name) { category in
                    Section(header: Text(category.name)) {
                        ForEach(category.types, id: \.self) { type in
                            Button { commitType(type) } label: {
                                typeRow(type)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(
                                top: 2, leading: 6, bottom: 2, trailing: 6
                            ))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: listHeight)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func typeRow(_ type: String) -> some View {
        if type.caseInsensitiveCompare(currentValue) == .orderedSame {
            Text(type)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(type)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func commitFreeform() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onCommit(text)
        onDismiss()
    }

    private func commitType(_ type: String) {
        onCommit(type)
        onDismiss()
    }
}
