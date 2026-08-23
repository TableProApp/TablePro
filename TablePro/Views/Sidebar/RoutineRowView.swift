//
//  RoutineRowView.swift
//  TablePro
//

import SwiftUI

enum RoutineRowLogic {
    static func accessibilityLabel(for routine: RoutineInfo, displayLabel: String) -> String {
        let kindLabel: String = routine.kind == .procedure
            ? String(localized: "Procedure")
            : String(localized: "Function")
        let baseLabel = "\(kindLabel): \(displayLabel)"
        guard let returnType = routine.returnType, !returnType.isEmpty else { return baseLabel }
        return String(format: String(localized: "%1$@, returns %2$@"), baseLabel, returnType)
    }

    static func iconName(for kind: RoutineInfo.Kind) -> String {
        switch kind {
        case .procedure: return "curlybraces.square"
        case .function:  return "function"
        }
    }

    /// The parts the row could not show: its full identity, then whatever the engine said about it.
    static func tooltip(for routine: RoutineInfo) -> String {
        var lines = [RoutineDisplayLabel.copyableSignature(for: routine)]
        if let returnType = routine.returnType, !returnType.isEmpty {
            lines.append(String(format: String(localized: "Returns %@"), returnType))
        }
        if let language = routine.language, !language.isEmpty {
            lines.append(String(format: String(localized: "Language %@"), language))
        }
        lines.append(contentsOf: routine.attributes.map { "\($0.label): \($0.value)" })
        return lines.joined(separator: "\n")
    }
}

struct RoutineRowView: View {
    let routine: RoutineInfo
    let displayLabel: String

    var body: some View {
        Label {
            Text(displayLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: RoutineRowLogic.iconName(for: routine.kind))
                .selectionAwareTint(Color.accentColor)
                .frame(width: 16)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RoutineRowLogic.accessibilityLabel(for: routine, displayLabel: displayLabel))
        .help(RoutineRowLogic.tooltip(for: routine))
    }
}
