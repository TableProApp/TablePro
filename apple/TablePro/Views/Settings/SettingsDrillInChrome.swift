//
//  SettingsDrillInChrome.swift
//  TablePro
//

import SwiftUI

// Title and a Back control for any page pushed onto a Settings pane's NavigationStack. The back
// button rides the window toolbar on macOS 14+ (the detail hosting controller bridges toolbars);
// macOS 13 cannot bridge it, so an inline bar carries the same button there.
private struct SettingsDrillInChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .navigation) { backButton }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if #unavailable(macOS 14.0) {
                    HStack {
                        backButton
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.backward")
        }
        .help(String(localized: "Back"))
        .accessibilityLabel(String(localized: "Back"))
    }
}

extension View {
    func settingsDrillIn(title: String) -> some View {
        modifier(SettingsDrillInChrome(title: title))
    }
}
