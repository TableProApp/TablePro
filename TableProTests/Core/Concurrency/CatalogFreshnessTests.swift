//
//  CatalogFreshnessTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CatalogFreshness")
struct CatalogFreshnessTests {
    @Test("A key never fetched is not current")
    func neverFetched() {
        let freshness = CatalogFreshness<String>()
        #expect(!freshness.isCurrent("shop"))
    }

    @Test("A committed fetch makes the key current")
    func committedFetch() {
        var freshness = CatalogFreshness<String>()
        let revision = freshness.revision(for: "shop")
        #expect(freshness.commit(revision, for: "shop"))
        #expect(freshness.isCurrent("shop"))
    }

    @Test("A change after the commit makes the key stale again")
    func changeAfterCommit() {
        var freshness = CatalogFreshness<String>()
        _ = freshness.commit(freshness.revision(for: "shop"), for: "shop")
        freshness.markChanged("shop")
        #expect(!freshness.isCurrent("shop"))
    }

    @Test("A fetch that started before a change commits its rows but leaves the key stale")
    func fetchOvertakenByChange() {
        var freshness = CatalogFreshness<String>()
        let started = freshness.revision(for: "shop")
        freshness.markChanged("shop")
        #expect(freshness.commit(started, for: "shop"))
        #expect(!freshness.isCurrent("shop"))
    }

    @Test("An older fetch finishing last cannot replace a newer one")
    func olderFetchFinishingLast() {
        var freshness = CatalogFreshness<String>()
        let older = freshness.revision(for: "shop")
        freshness.markChanged("shop")
        let newer = freshness.revision(for: "shop")
        #expect(freshness.commit(newer, for: "shop"))
        #expect(!freshness.commit(older, for: "shop"))
        #expect(freshness.isCurrent("shop"))
    }

    @Test("A change to one key leaves another current")
    func keysAreIndependent() {
        var freshness = CatalogFreshness<String>()
        _ = freshness.commit(freshness.revision(for: "shop"), for: "shop")
        _ = freshness.commit(freshness.revision(for: "blog"), for: "blog")
        freshness.markChanged("blog")
        #expect(freshness.isCurrent("shop"))
        #expect(!freshness.isCurrent("blog"))
    }

    @Test("Removed keys are fetched again")
    func removedKeys() {
        var freshness = CatalogFreshness<String>()
        _ = freshness.commit(freshness.revision(for: "shop"), for: "shop")
        freshness.removeAll { $0 == "shop" }
        #expect(!freshness.isCurrent("shop"))
    }
}
