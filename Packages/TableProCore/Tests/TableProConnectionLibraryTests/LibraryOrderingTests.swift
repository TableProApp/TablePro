import Foundation
@testable import TableProConnectionLibrary
import Testing

@Suite("Library ordering")
struct LibraryOrderingTests {
    @Test("The next sort order follows the largest existing one")
    func nextSortOrder() {
        #expect(LibraryOrdering.nextSortOrder(after: []) == 0)
        #expect(LibraryOrdering.nextSortOrder(after: [0, 0, 4, 2]) == 5)
    }

    @Test("Moving items places them before the target in the given order")
    func reorderBefore() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(LibraryOrdering.reordered([a, b, c], moving: [c, d], before: b) == [a, c, d, b])
    }

    @Test("Moving without a target appends")
    func reorderAppend() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(LibraryOrdering.reordered([a, b, c], moving: [a], before: nil) == [b, c, a])
    }

    @Test("A target that is itself moving falls back to the end")
    func reorderMovingTarget() {
        let a = UUID(), b = UUID()
        #expect(LibraryOrdering.reordered([a, b], moving: [a], before: a) == [b, a])
    }

    @Test("Ranks number the order from zero")
    func ranks() {
        let a = UUID(), b = UUID()
        #expect(LibraryOrdering.ranks(for: [b, a]) == [b: 0, a: 1])
    }

    @Test("Favorites order drops ids that are no longer favorites")
    func favoritesKeeping() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(LibraryOrdering.favoritesOrder([a, b, c, a], keeping: [a, c]) == [a, c])
        #expect(LibraryOrdering.favoritesOrder([a, b], removing: [a]) == [b])
    }
}
