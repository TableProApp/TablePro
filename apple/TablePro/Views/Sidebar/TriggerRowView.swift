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

    /// Under a schema's Triggers group the table tells two same-named triggers apart. Under the table
    /// itself that name is the row above, so the caption says when the trigger fires instead.
    static func caption(for trigger: TriggerInfo, listedUnderTable: Bool) -> String? {
        guard listedUnderTable else {
            guard let table = trigger.table, !table.isEmpty else { return nil }
            return table
        }
        let firing = [trigger.timing, trigger.event].filter { !$0.isEmpty }.joined(separator: " ")
        return firing.isEmpty ? nil : firing
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
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let trigger: TriggerInfo
    var listedUnderTable = false

    private var objectIcon: ObjectIcon {
        ObjectIconProvider.icon(for: .trigger, style: settingsManager.appearance.objectIconStyle)
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(trigger.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let caption = TriggerRowLogic.caption(for: trigger, listedUnderTable: listedUnderTable) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(listedUnderTable ? .tail : .head)
                }
            }
        } icon: {
            objectIcon.image
                .objectIconTint(objectIcon, standard: Color.accentColor)
                .frame(width: 16)
        }
        .sidebarRowIcon(visible: settingsManager.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TriggerRowLogic.accessibilityLabel(for: trigger))
        .help(TriggerRowLogic.tooltip(for: trigger))
    }
}
