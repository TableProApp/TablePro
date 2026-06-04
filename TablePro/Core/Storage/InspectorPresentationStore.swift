//
//  InspectorPresentationStore.swift
//  TablePro
//

import Foundation

struct InspectorPresentationStore: @unchecked Sendable {
    static let shared = InspectorPresentationStore(userDefaults: .standard)

    private static let isPresentedKey = "com.TablePro.rightPanel.isPresented"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isPresented: Bool {
        userDefaults.bool(forKey: Self.isPresentedKey)
    }

    func setPresented(_ isPresented: Bool) {
        userDefaults.set(isPresented, forKey: Self.isPresentedKey)
    }
}
