//
//  SidebarViewOptionsMenu.swift
//  TablePro
//

import SwiftUI

struct SidebarViewOptionsMenu: View {
    @State private var settingsManager = AppSettingsManager.shared

    var body: some View {
        Menu(String(localized: "View Options")) {
            Toggle("Icons", isOn: $settingsManager.general.showObjectIcons)
            Toggle("Comments", isOn: $settingsManager.general.showObjectComments)

            Divider()

            /// An inline picker adds checkable items to this menu rather than a second level of
            /// nesting, which is how a menu offers one choice out of a short list.
            Picker(String(localized: "Row Size"), selection: $settingsManager.general.sidebarRowSize) {
                ForEach(SidebarRowSizePreference.allCases, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.inline)
        }
    }
}
