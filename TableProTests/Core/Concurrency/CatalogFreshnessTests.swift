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
        let committed = freshness.commit(revision, for: "shop")
        #expect(committed)
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
        let committed = freshness.commit(started, for: "shop")
        #expect(committed)
        #expect(!freshness.isCurrent("shop"))
    }

    @Test("An older fetch finishing last cannot replace a newer one")
    func olderFetchFinishingLast() {
        var freshness = CatalogFreshness<String>()
        let older = freshness.revision(for: "shop")
        freshness.markChanged("shop")
        let newer = freshness.revision(for: "shop")
        let newerCommitted = freshness.commit(newer, for: "shop")
        let olderCommitted = freshness.commit(older, for: "shop")
        #expect(newerCommitted)
        #expect(!olderCommitted)
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

    @Test("A key never fetched needs a fetch, and only until one starts")
    func needsFetchUntilOneStarts() {
        var freshness = CatalogFreshness<String>()
        #expect(freshness.needsFetch("shop"))
        freshness.noteFetchStarted(freshness.revision(for: "shop"), for: "shop")
        #expect(!freshness.needsFetch("shop"))
    }

    @Test("A current key needs no fetch until a change overtakes it")
    func currentKeyNeedsNoFetch() {
        var freshness = CatalogFreshness<String>()
        let revision = freshness.revision(for: "shop")
        freshness.noteFetchStarted(revision, for: "shop")
        _ = freshness.commit(revision, for: "shop")
        #expect(!freshness.needsFetch("shop"))
        freshness.markChanged("shop")
        #expect(freshness.needsFetch("shop"))
    }

    /// Every reader that observes a failed fetch would otherwise ask for it again, and a failure
    /// publishes a change every reader observes.
    @Test("A fetch that failed is not asked for again until the next change")
    func failedFetchWaitsForTheNextChange() {
        var freshness = CatalogFreshness<String>()
        freshness.markChanged("shop")
        freshness.noteFetchStarted(freshness.revision(for: "shop"), for: "shop")
        #expect(!freshness.needsFetch("shop"))
        freshness.markChanged("shop")
        #expect(freshness.needsFetch("shop"))
    }

    @Test("A fetch cut short is asked for again at the same revision")
    func abandonedFetchIsAskedForAgain() {
        var freshness = CatalogFreshness<String>()
        let revision = freshness.revision(for: "shop")
        freshness.noteFetchStarted(revision, for: "shop")
        freshness.noteFetchAbandoned(revision, for: "shop")
        #expect(freshness.needsFetch("shop"))
    }

    @Test("Abandoning an older fetch leaves a newer one standing")
    func abandoningAnOlderFetch() {
        var freshness = CatalogFreshness<String>()
        let older = freshness.revision(for: "shop")
        freshness.noteFetchStarted(older, for: "shop")
        freshness.markChanged("shop")
        freshness.noteFetchStarted(freshness.revision(for: "shop"), for: "shop")
        freshness.noteFetchAbandoned(older, for: "shop")
        #expect(!freshness.needsFetch("shop"))
    }
}
