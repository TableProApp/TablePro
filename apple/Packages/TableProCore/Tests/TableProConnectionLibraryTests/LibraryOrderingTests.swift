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

    @Test("Reordering one project's favorites permutes them in place and leaves the others where they were")
    func scopedReorderKeepsTheRest() {
        let a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID()
        let saved = [b1, a1, b2, a2]

        #expect(LibraryOrdering.favoritesOrder(saved, scoped: [a1, a2], reorderedTo: [a2, a1]) == [b1, a2, b2, a1])
    }

    @Test("A favorite removed in one project leaves the saved order of the others")
    func scopedRemovalKeepsTheRest() {
        let a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID()

        #expect(LibraryOrdering.favoritesOrder([b1, a1, b2, a2], scoped: [a1, a2], reorderedTo: [a2]) == [b1, a2, b2])
    }

    @Test("A favorite added in one project lands among that project's, after the others before it")
    func scopedInsertKeepsTheRest() {
        let a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID(), added = UUID()
        let saved = [b1, a1, b2, a2]

        #expect(
            LibraryOrdering.favoritesOrder(saved, scoped: [a1, a2], reorderedTo: [added, a1, a2])
                == [b1, added, b2, a1, a2]
        )
        #expect(LibraryOrdering.favoritesOrder([b1, b2], scoped: [], reorderedTo: [added]) == [b1, b2, added])
    }

    @Test("With everything in scope the saved order becomes the new one, unranked favorites included")
    func unscopedReorderReplaces() {
        let a = UUID(), b = UUID(), c = UUID(), unranked = UUID()

        #expect(
            LibraryOrdering.favoritesOrder([a, b, c], scoped: [a, b, c, unranked], reorderedTo: [c, unranked, a, b])
                == [c, unranked, a, b]
        )
    }

    @Test("Favorites order drops ids that are no longer favorites")
    func favoritesKeeping() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(LibraryOrdering.favoritesOrder([a, b, c, a], keeping: [a, c]) == [a, c])
        #expect(LibraryOrdering.favoritesOrder([a, b], removing: [a]) == [b])
    }
}
