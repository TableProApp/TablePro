//
//  ConnectionListPreferencesTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
internal struct ConnectionListPreferencesTests {
    private let suiteName = "com.TablePro.tests.ConnectionListPreferences.\(UUID().uuidString)"
    private let defaults: UserDefaults

    internal init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    private func makePreferences() -> ConnectionListPreferences {
        ConnectionListPreferences(defaults: defaults, appEvents: AppEvents())
    }

    @Test("Recent is shown until the user hides it")
    internal func showsRecentByDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(makePreferences().showsRecent)
    }

    @Test("Hiding Recent survives a relaunch on this Mac")
    internal func hidingRecentPersists() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        makePreferences().setShowsRecent(false)

        #expect(!makePreferences().showsRecent)
    }

    @Test("Resetting shows Recent again and forgets the stored choice")
    internal func resetRestoresTheDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = makePreferences()
        preferences.setShowsRecent(false)

        preferences.resetShowsRecent()

        #expect(preferences.showsRecent)
        #expect(defaults.object(forKey: PreferenceKeys.connectionListShowsRecent.name) == nil)
        #expect(makePreferences().showsRecent)
    }

    @Test("Only a real change is published")
    internal func publishesOnlyChanges() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = makePreferences()
        var received: [Bool] = []
        let cancellable = preferences.$showsRecent.dropFirst().sink { received.append($0) }

        preferences.setShowsRecent(true)
        preferences.setShowsRecent(false)
        preferences.setShowsRecent(false)
        preferences.resetShowsRecent()
        preferences.resetShowsRecent()
        cancellable.cancel()

        #expect(received == [false, true])
    }
}
