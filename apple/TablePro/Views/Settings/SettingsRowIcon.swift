//
//  SettingsRowIcon.swift
//  TablePro
//

import SwiftUI

// The colorful rounded-square tile a System Settings sidebar row shows: a white SF Symbol on a
// fixed per-category tint. The tint is a hardcoded system color, never a theme slot, so the Settings
// chrome stays off the theme engine (.claude/rules/theme.md).
struct SettingsRowIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
