//
//  SettingsDrillInChrome.swift
//  TablePro
//

import SwiftUI

// A pushed Settings page reports its title up to the pane's NavigationStack, which hands it to the
// window toolbar (shown next to the Back control, System Settings style). The Back button and the
// title live in the toolbar, so a drill-in page adds no chrome of its own.
struct SettingsPageTitleKey: PreferenceKey {
    static var defaultValue: String? { nil }

    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    func settingsDrillIn(title: String) -> some View {
        navigationTitle(title)
            .preference(key: SettingsPageTitleKey.self, value: title)
    }
}
