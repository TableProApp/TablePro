//
//  QueryContainerPicker.swift
//  TablePro
//
//  Per-tab container (database/schema) selector shown in the query editor
//  toolbar. Binds a query tab to the container its SQL runs in, so each tab
//  can target a different database without clearing the others.
//

import SwiftUI

struct QueryContainerPicker: View {
    let containers: [DatabaseMetadata]
    let selectedName: String
    let entityName: String
    let isReadOnly: Bool
    let onChange: (String) -> Void

    var body: some View {
        if isReadOnly {
            readOnlyLabel
        } else if containers.count > 1 {
            menu
        } else if !selectedName.isEmpty {
            indicatorLabel
        } else {
            EmptyView()
        }
    }

    private var selectedIcon: String {
        containers.first(where: { $0.name == selectedName })?.icon ?? "cylinder"
    }

    private var menu: some View {
        Menu {
            ForEach(containers) { container in
                Button {
                    if container.name != selectedName { onChange(container.name) }
                } label: {
                    Label(container.name, systemImage: container.name == selectedName ? "checkmark" : container.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedIcon)
                    .font(.body)
                Text(selectedName.isEmpty ? entityName : selectedName)
                    .font(.callout)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(entityName)
    }

    private var readOnlyLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: selectedIcon)
                .font(.body)
            Text(selectedName)
                .font(.callout)
                .lineLimit(1)
            Image(systemName: "lock.fill")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .help(String(format: String(localized: "%@ switches reconnect the session"), entityName))
    }

    private var indicatorLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: selectedIcon)
                .font(.body)
            Text(selectedName)
                .font(.callout)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(entityName)
    }
}
