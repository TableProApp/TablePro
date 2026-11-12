//
//  ConnectionNavigatorExpansionStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ConnectionNavigatorExpansionStoreTests {
    private let suite: EphemeralDefaults
    private let store: ConnectionNavigatorExpansionStore

    init() throws {
        suite = try EphemeralDefaults()
        store = ConnectionNavigatorExpansionStore(defaults: suite.defaults)
    }

    @Test("Expanded groups come back as they were saved")
    func roundTrips() {
        let first = UUID()
        let second = UUID()
        store.save([first, second])

        #expect(store.load(keeping: [first, second, UUID()]) == [first, second])
    }

    @Test("A group that no longer exists is dropped on load")
    func dropsUnknownGroups() {
        let kept = UUID()
        store.save([kept, UUID()])

        #expect(store.load(keeping: [kept]) == [kept])
    }

    @Test("Nothing saved reads as every group collapsed")
    func missingKeyReadsEmpty() {
        #expect(store.load(keeping: [UUID()]).isEmpty)
    }

    @Test("The set is stored under the navigator's own key")
    func writesItsOwnKey() throws {
        let first = UUID()
        let second = UUID()
        store.save([first, second])

        let stored = try #require(suite.defaults.stringArray(forKey: "com.TablePro.navigator.groupExpansion"))
        #expect(Set(stored) == [first.uuidString, second.uuidString])
    }
}
