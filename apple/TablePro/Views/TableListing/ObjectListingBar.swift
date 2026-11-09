//
//  ObjectListingBar.swift
//  TablePro
//

import SwiftUI

internal struct ObjectListingBar: View {
    @ObservedObject var model: TableListingViewModel
    let kinds: [SidebarObjectKind]
    let kindTitle: (SidebarObjectKind) -> String
    let onSelectKind: (SidebarObjectKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(String(localized: "Object Kind"), selection: kindSelection) {
                    ForEach(kinds, id: \.self) { kind in
                        Text(kindTitle(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("objects-kind-picker")

                NativeSearchField(
                    text: $model.filterText,
                    placeholder: String(localized: "Filter by Name"),
                    controlSize: .small,
                    maxWidth: 240,
                    accessibilityIdentifier: "objects-name-filter"
                )
                .disabled(!model.rowsNameObjects)

                Spacer(minLength: 8)

                if let count = model.count {
                    ObjectListingCountText(count: count)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                PaneRefreshControls(
                    isRefreshing: model.isRefreshing,
                    lastRefreshDate: nil,
                    accessibilityIdentifier: "objects-refresh-button"
                ) {
                    model.reload()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
        }
        .paneBarBackground()
    }

    private var kindSelection: Binding<SidebarObjectKind> {
        Binding(get: { model.target.kind }, set: { onSelectKind($0) })
    }
}

// The picker names the kind, so the count says objects. The number sits inside the inflect span, so the
// noun agrees with it in every language.
internal struct ObjectListingCountText: View {
    let count: ObjectListingCount

    var body: some View {
        if count.shown == count.total {
            Text("^[\(count.total) object](inflect: true)")
        } else {
            Text("\(count.shown) of ^[\(count.total) object](inflect: true)")
        }
    }
}
