//
//  ObjectListingBar.swift
//  TablePro
//

import SwiftUI

/// The Objects tab's tool strip: the object commands on the left, then what narrows the list on the right.
internal struct ObjectListingBar: View {
    @ObservedObject var model: TableListingViewModel
    @ObservedObject var list: ObjectListingList
    let kinds: [SidebarObjectKind]
    let kindTitle: (SidebarObjectKind) -> String
    let onSelectKind: (SidebarObjectKind) -> Void

    var body: some View {
        let availability = model.commandAvailability
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    command(String(localized: "Open"), "arrow.up.forward.square", "objects-open-button",
                            enabled: availability.canOpen, model.openSelection)
                    command(String(localized: "Show Structure"), "pencil.and.ruler", "objects-design-button",
                            enabled: availability.canDesign, model.designSelection)
                    command(String(localized: "New Table"), "plus.circle", "objects-new-button",
                            enabled: availability.canCreate, model.createObject)
                    command(String(localized: "Delete"), "minus.circle", "objects-delete-button",
                            enabled: availability.canDelete, model.deleteSelection)
                    groupDivider
                    command(String(localized: "Import"), "square.and.arrow.down", "objects-import-button",
                            enabled: availability.canImport, model.importData)
                    command(String(localized: "Export"), "square.and.arrow.up", "objects-export-button",
                            enabled: availability.canExport, model.exportSelection)
                    groupDivider
                    PaneRefreshControls(
                        isRefreshing: model.isRefreshing,
                        lastRefreshDate: nil,
                        accessibilityIdentifier: "objects-refresh-button"
                    ) {
                        model.reload()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer(minLength: 8)

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
                    maxWidth: 200,
                    accessibilityIdentifier: "objects-name-filter"
                )
                .disabled(!model.rowsNameObjects)

                if let count = model.count {
                    ObjectListingCountText(count: count)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()
        }
        .paneBarBackground()
    }

    private var groupDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 4)
    }

    private func command(
        _ title: String,
        _ symbol: String,
        _ identifier: String,
        enabled: Bool,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(width: 24, height: 20)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
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
