//
//  ColumnCheckList.swift
//  TablePro
//

import SwiftUI

struct ColumnCheckListItem: Identifiable, Hashable, Sendable {
    let name: String
    let typeName: String?

    var id: String { name }
}

/// A ticked list of column names, the shape the app uses wherever a reader chooses some columns
/// out of a table's own: the grid's column visibility popover and the foreign key picker's label
/// chooser.
///
/// The search field appears only past `searchThreshold` columns, because a list short enough to
/// read at a glance is longer with a search field above it than without one.
struct ColumnCheckList: View {
    static let searchThreshold = 5

    let items: [ColumnCheckListItem]
    @Binding var searchText: String
    let searchPlaceholder: String
    let searchAccessibilityIdentifier: String
    let rowAccessibilityIdentifierPrefix: String
    let listMinHeight: CGFloat
    let listMaxHeight: CGFloat
    let isChecked: (String) -> Bool
    let onToggle: (String) -> Void

    private var filteredItems: [ColumnCheckListItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.count > Self.searchThreshold {
                searchField
                Divider()
            }
            list
        }
    }

    private var searchField: some View {
        NativeSearchField(
            text: $searchText,
            placeholder: searchPlaceholder,
            controlSize: .small,
            accessibilityIdentifier: searchAccessibilityIdentifier
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        List {
            ForEach(filteredItems) { item in
                row(item)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: listMinHeight, maxHeight: listMaxHeight)
    }

    private func row(_ item: ColumnCheckListItem) -> some View {
        Toggle(isOn: Binding(
            get: { isChecked(item.name) },
            set: { _ in onToggle(item.name) }
        )) {
            HStack(spacing: 8) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let typeName = item.typeName {
                    Text(typeName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("\(rowAccessibilityIdentifierPrefix)\(item.name)")
    }
}
