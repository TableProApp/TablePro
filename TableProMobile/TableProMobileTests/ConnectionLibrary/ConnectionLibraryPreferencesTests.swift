import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import Testing

@MainActor
@Suite("Connection library preferences")
struct ConnectionLibraryPreferencesTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.LibraryPreferences.\(UUID().uuidString)"))
    }

    @Test("Sort, favorites order, recents and collapsed groups survive a relaunch")
    func persists() {
        let preferences = ConnectionLibraryPreferences(defaults: defaults)
        let first = UUID()
        let second = UUID()
        let group = UUID()

        preferences.setSortMode(.name)
        preferences.setFavoritesOrder([second, first, second])
        preferences.recordConnected(first, at: Date(timeIntervalSince1970: 10))
        preferences.setGroup(group, expanded: false)

        let relaunched = ConnectionLibraryPreferences(defaults: defaults)
        #expect(relaunched.sortMode == .name)
        #expect(relaunched.favoritesOrder == [second, first])
        #expect(relaunched.lastConnected[first] == Date(timeIntervalSince1970: 10))
        #expect(!relaunched.isGroupExpanded(group))
        #expect(relaunched.isGroupExpanded(UUID()))
    }

    @Test("Pruning forgets deleted connections, removed favorites and deleted groups")
    func prunes() {
        let preferences = ConnectionLibraryPreferences(defaults: defaults)
        let kept = UUID()
        let deleted = UUID()
        let unfavorited = UUID()
        let keptGroup = UUID()
        let deletedGroup = UUID()
        preferences.setFavoritesOrder([kept, unfavorited, deleted])
        preferences.recordConnected(kept)
        preferences.recordConnected(deleted)
        preferences.setGroup(keptGroup, expanded: false)
        preferences.setGroup(deletedGroup, expanded: false)

        preferences.prune(connectionIds: [kept, unfavorited], favoriteIds: [kept], groupIds: [keptGroup])

        #expect(preferences.favoritesOrder == [kept])
        #expect(Set(preferences.lastConnected.keys) == [kept])
        #expect(preferences.collapsedGroupIds == [keptGroup])
    }

    @Test("Removing one connection from Recent keeps the others")
    func removeFromRecent() {
        let preferences = ConnectionLibraryPreferences(defaults: defaults)
        let first = UUID()
        let second = UUID()
        preferences.recordConnected(first)
        preferences.recordConnected(second)

        preferences.removeFromRecent([first])

        #expect(Set(preferences.lastConnected.keys) == [second])
    }
}
