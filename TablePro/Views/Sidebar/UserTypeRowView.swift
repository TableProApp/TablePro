//
//  UserTypeRowView.swift
//  TablePro
//

import SwiftUI

enum UserTypeRowLogic {
    static func accessibilityLabel(for type: UserDefinedTypeInfo) -> String {
        "\(type.kind.displayName): \(type.name)"
    }

    /// The row shows the name; what the type is made of goes here, because that is what tells an
    /// enum from a domain before the reader opens either.
    static func tooltip(for type: UserDefinedTypeInfo) -> String {
        var lines = [type.qualifiedName, type.kind.displayName]
        switch type.kind {
        case .enumeration where !type.enumLabels.isEmpty:
            lines.append(type.enumLabels.joined(separator: ", "))
        case .composite where !type.fields.isEmpty:
            lines.append(type.fields.map { "\($0.name) \($0.type)" }.joined(separator: ", "))
        case .domain, .range:
            if let baseType = type.baseType, !baseType.isEmpty { lines.append(baseType) }
        default:
            break
        }
        lines.append(contentsOf: type.attributes.map { "\($0.label): \($0.value)" })
        return lines.joined(separator: "\n")
    }
}

struct UserTypeRowView: View {
    let type: UserDefinedTypeInfo

    var body: some View {
        Label {
            Text(type.name)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: type.kind.iconName)
                .selectionAwareTint(Color.accentColor)
                .frame(width: 16)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UserTypeRowLogic.accessibilityLabel(for: type))
        .help(UserTypeRowLogic.tooltip(for: type))
    }
}
