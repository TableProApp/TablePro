//
//  RoutineRowView.swift
//  TablePro
//

import SwiftUI

enum RoutineRowLogic {
    static func accessibilityLabel(for routine: RoutineInfo) -> String {
        let kindLabel: String = routine.kind == .procedure
            ? String(localized: "Procedure")
            : String(localized: "Function")
        let baseLabel = "\(kindLabel): \(routine.name)"
        if let signature = routine.signature, !signature.isEmpty {
            return "\(baseLabel), \(signature)"
        }
        return baseLabel
    }

    static func iconName(for kind: RoutineInfo.Kind) -> String {
        switch kind {
        case .procedure: return "curlybraces.square"
        case .function:  return "function"
        }
    }

    static func iconColor(for kind: RoutineInfo.Kind) -> Color {
        switch kind {
        case .procedure: return Color(nsColor: .systemTeal)
        case .function:  return Color(nsColor: .systemCyan)
        }
    }

    static func tooltip(for routine: RoutineInfo) -> String? {
        guard let signature = routine.signature, !signature.isEmpty else { return nil }
        return signature
    }
}

struct RoutineRowView: View {
    let routine: RoutineInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: RoutineRowLogic.iconName(for: routine.kind))
                .foregroundStyle(RoutineRowLogic.iconColor(for: routine.kind))
                .frame(width: 14)

            Text(routine.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RoutineRowLogic.accessibilityLabel(for: routine))
        .help(RoutineRowLogic.tooltip(for: routine) ?? routine.name)
    }
}

struct RoutineContextMenu: View {
    let routine: RoutineInfo
    let onShowDDL: (RoutineInfo) -> Void

    var body: some View {
        Button(String(localized: "Copy Name")) {
            ClipboardService.shared.writeText(routine.name)
        }
        if let signature = routine.signature, !signature.isEmpty {
            Button(String(localized: "Copy with Signature")) {
                ClipboardService.shared.writeText("\(routine.name)\(signature)")
            }
        }
        Divider()
        Button(String(localized: "Show DDL")) {
            onShowDDL(routine)
        }
    }
}
