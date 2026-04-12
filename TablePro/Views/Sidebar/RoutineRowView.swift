//
//  RoutineRowView.swift
//  TablePro
//
//  Row view for a stored procedure or function in the sidebar.
//

import SwiftUI

struct RoutineRow: View {
    let routine: RoutineInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: routine.type == .function ? "f.cursive" : "gearshape.2")
                .foregroundStyle(routine.type == .function
                    ? Color(nsColor: .systemTeal)
                    : Color(nsColor: .systemGreen))
                .frame(width: ThemeEngine.shared.activeTheme.iconSizes.default)

            Text(routine.name)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(routine.type == .function
            ? String(format: String(localized: "Function: %@"), routine.name)
            : String(format: String(localized: "Procedure: %@"), routine.name))
    }
}
