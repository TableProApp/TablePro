//
//  InspectorPresentationStoreTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

private func makeInspectorPresentationDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.InspectorPresentationStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Suite("InspectorPresentationStore")
struct InspectorPresentationStoreTests {
    @Test("defaults to hidden")
    func defaultsToHidden() {
        let (defaults, suiteName) = makeInspectorPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = InspectorPresentationStore(userDefaults: defaults)

        #expect(store.isPresented == false)
    }

    @Test("persists presentation state")
    func persistsPresentationState() {
        let (defaults, suiteName) = makeInspectorPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = InspectorPresentationStore(userDefaults: defaults)

        store.setPresented(true)
        #expect(store.isPresented)

        store.setPresented(false)
        #expect(store.isPresented == false)
    }
}
