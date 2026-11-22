//
//  SettingsDrillInChrome.swift
//  TablePro
//

import SwiftUI

// Title and a Back control for any page pushed onto a Settings pane's NavigationStack. The control
// sits at the top of the detail column (like System Settings), not in the window toolbar, so it
// never overlaps the sidebar.
private struct SettingsDrillInChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Back"))
                    .accessibilityLabel(String(localized: "Back"))

                    Text(title)
                        .font(.headline)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
    }
}

extension View {
    func settingsDrillIn(title: String) -> some View {
        modifier(SettingsDrillInChrome(title: title))
    }
}
