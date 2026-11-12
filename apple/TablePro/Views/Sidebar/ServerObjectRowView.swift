//
//  ServerObjectRowView.swift
//  TablePro
//

import SwiftUI

enum ServerObjectRowLogic {
    static func displayName(for object: ServerObjectInfo, kind: SidebarServerObjectKind) -> String {
        kind.scope == .database ? object.name : IdentityPath.qualified(name: object.name, schema: object.schema)
    }

    static func accessibilityLabel(for object: ServerObjectInfo, kind: SidebarServerObjectKind) -> String {
        let base = String(format: String(localized: "%1$@: %2$@"), kind.displayName, object.name)
        guard let detail = object.detail, !detail.isEmpty else { return base }
        return base + ", " + detail
    }

    // The driver states the object's state in its attributes, in its own words, so it is not repeated here.
    static func tooltip(for object: ServerObjectInfo, kind: SidebarServerObjectKind) -> String {
        var lines: [String] = [displayName(for: object, kind: kind)]
        if let detail = object.detail, !detail.isEmpty { lines.append(detail) }
        lines.append(contentsOf: object.attributes.map { "\($0.label): \($0.value)" })
        return lines.joined(separator: "\n")
    }
}

// Plain drawn values: `ServerObjectInfo` compares by id, so a refreshed version or state would read as unchanged.
struct ServerObjectRowView: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let name: String
    let detail: String?
    let iconName: String
    let tooltip: String
    let accessibilityLabel: String

    init(name: String, detail: String?, iconName: String, tooltip: String, accessibilityLabel: String) {
        self.name = name
        self.detail = detail
        self.iconName = iconName
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
    }

    init(object: ServerObjectInfo, kind: SidebarServerObjectKind) {
        self.init(
            name: object.name,
            detail: object.detail,
            iconName: kind.iconName,
            tooltip: ServerObjectRowLogic.tooltip(for: object, kind: kind),
            accessibilityLabel: ServerObjectRowLogic.accessibilityLabel(for: object, kind: kind)
        )
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } icon: {
            Image(systemName: iconName)
                .selectionAwareTint(Color.accentColor)
                .frame(width: 16)
        }
        .sidebarRowIcon(visible: settingsManager.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .help(tooltip)
    }
}
