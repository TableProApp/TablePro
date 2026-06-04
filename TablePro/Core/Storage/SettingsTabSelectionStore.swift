//
//  SettingsTabSelectionStore.swift
//  TablePro
//

import Foundation

struct SettingsTabSelectionStore: @unchecked Sendable {
    static let shared = SettingsTabSelectionStore(userDefaults: .standard)
    static let selectedTabKey = "selectedSettingsTab"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func select(_ tab: SettingsTab) {
        userDefaults.set(tab.rawValue, forKey: Self.selectedTabKey)
    }
}
