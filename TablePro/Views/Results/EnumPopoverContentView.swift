//
//  EnumPopoverContentView.swift
//  TablePro
//
//  Searchable dropdown for ENUM column editing.
//

import SwiftUI

private let enumNullMarker = "\u{2300} NULL"

struct EnumPopoverContentView: View {
    let allValues: [String]
    let currentValue: String?
    let isNullable: Bool
    let onCommit: (String?) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private static let rowHeight: CGFloat = 24
    private static let searchAreaHeight: CGFloat = 44
    private static let maxHeight: CGFloat = 320

    private var filteredValues: [String] {
        let query = searchText.lowercased()
        if query.isEmpty { return allValues }
        return allValues.filter { $0.lowercased().contains(query) }
    }

    private var listHeight: CGFloat {
        let contentHeight = CGFloat(filteredValues.count) * Self.rowHeight
        return min(contentHeight, Self.maxHeight - Self.searchAreaHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            Divider()

            List {
                ForEach(filteredValues, id: \.self) { value in
                    rowLabel(for: value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { commitValue(value) }
                        .listRowInsets(EdgeInsets(
                            top: 2, leading: 6, bottom: 2, trailing: 6
                        ))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: listHeight)
            .onKeyPress(.return) {
                guard let firstValue = filteredValues.first else { return .ignored }
                commitValue(firstValue)
                return .handled
            }
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func rowLabel(for value: String) -> some View {
        if value == enumNullMarker {
            Text(value)
                .font(.system(.callout, design: .monospaced).italic())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if value == currentValue {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func commitValue(_ value: String) {
        if value == enumNullMarker {
            onCommit(nil)
        } else {
            onCommit(value)
        }
        onDismiss()
    }
}
