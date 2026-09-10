//
//  TriggerRowView.swift
//  TablePro
//

import SwiftUI

enum TriggerRowLogic {
    static func accessibilityLabel(for trigger: TriggerInfo) -> String {
        let base = String(format: String(localized: "Trigger: %@"), trigger.name)
        guard let table = trigger.table, !table.isEmpty else { return base }
        return String(format: String(localized: "%1$@ on %2$@"), base, table)
    }

    /// The row shows the name; the table it fires for, its timing and its event go here, because
    /// those are what tell two same-named triggers apart in a database-wide list.
    static func tooltip(for trigger: TriggerInfo) -> String {
        var lines: [String] = [trigger.qualifiedName]
        let firing = [trigger.timing, trigger.event, trigger.orientation]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        if !firing.isEmpty { lines.append(firing) }
        if let enabled = trigger.enabled {
            lines.append(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        }
        lines.append(contentsOf: trigger.attributes.map { "\($0.label): \($0.value)" })
        return lines.joined(separator: "\n")
    }
}

struct TriggerRowView: View {
    let trigger: TriggerInfo

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(trigger.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let table = trigger.table, !table.isEmpty {
                    Text(table)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } icon: {
            Image(systemName: SidebarObjectKind.trigger.iconName)
                .selectionAwareTint(Color.accentColor)
                .frame(width: 16)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TriggerRowLogic.accessibilityLabel(for: trigger))
        .help(TriggerRowLogic.tooltip(for: trigger))
    }
}
