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
    /// The schema half of the tab's scope, when the engine has schemas under a database and the
    /// container being switched is the database. Completion resolves against database AND schema,
    /// so a control naming only the database describes half of what the tab is bound to.
    let schemaName: String?
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

    /// What the tab is bound to, spelled the way the sidebar spells a qualified object.
    private var scopeLabel: String {
        let base = selectedName.isEmpty ? entityName : selectedName
        guard let schemaName, !schemaName.isEmpty, !selectedName.isEmpty else { return base }
        return "\(base) · \(schemaName)"
    }

    private var scopeAccessibilityLabel: String {
        guard let schemaName, !schemaName.isEmpty, !selectedName.isEmpty else { return entityName }
        return String(format: String(localized: "%1$@, schema %2$@"), selectedName, schemaName)
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
                Text(scopeLabel)
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
        .accessibilityLabel(scopeAccessibilityLabel)
    }

    private var readOnlyLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: selectedIcon)
                .font(.body)
            Text(scopeLabel)
                .font(.callout)
                .lineLimit(1)
            Image(systemName: "lock.fill")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(scopeAccessibilityLabel)
        .help(String(format: String(localized: "%@ switches reconnect the session"), entityName))
    }

    private var indicatorLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: selectedIcon)
                .font(.body)
            Text(scopeLabel)
                .font(.callout)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(scopeAccessibilityLabel)
    }
}
