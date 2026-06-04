//
//  WelcomeViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

private let expandedGroupIdsKey = "com.TablePro.expandedGroupIds"
private let collapsedGroupIdsKey = "com.TablePro.collapsedGroupIds"

private func makeWelcomeDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.WelcomeViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Suite("WelcomeViewModel")
struct WelcomeViewModelTests {
    @Test("loads and persists expanded groups through injected defaults")
    @MainActor
    func expandedGroupsUseInjectedDefaults() {
        let (defaults, suiteName) = makeWelcomeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistedId = UUID()
        defaults.set([persistedId.uuidString], forKey: expandedGroupIdsKey)

        let vm = WelcomeViewModel(services: .live, userDefaults: defaults)

        #expect(vm.expandedGroupIds == Set([persistedId]))

        let nextId = UUID()
        vm.expandedGroupIds = Set([nextId])

        let storedIds = Set(
            (defaults.stringArray(forKey: expandedGroupIdsKey) ?? [])
                .compactMap { UUID(uuidString: $0) }
        )
        #expect(storedIds == Set([nextId]))
    }

    @Test("clears legacy collapsed groups when no expanded groups are stored")
    @MainActor
    func emptyExpandedGroupsClearLegacyCollapsedGroups() {
        let (defaults, suiteName) = makeWelcomeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([UUID().uuidString], forKey: collapsedGroupIdsKey)

        let vm = WelcomeViewModel(services: .live, userDefaults: defaults)

        #expect(vm.expandedGroupIds.isEmpty)
        #expect(defaults.object(forKey: collapsedGroupIdsKey) == nil)
    }
}
