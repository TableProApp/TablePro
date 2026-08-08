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
        }
    }
}
