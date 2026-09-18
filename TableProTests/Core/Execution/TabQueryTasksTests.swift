//
//  TabQueryTasksTests.swift
//  TableProTests
//
//  One query task per tab. The handle used to be one per window, which made every start path a Stop
//  for whichever tab happened to hold it.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Tab query tasks")
struct TabQueryTasksTests {
    @Test("Installing on an idle tab displaces nothing")
    func installOnIdleTabDisplacesNothing() {
        var tasks = TabQueryTasks()
        let tabId = UUID()
        let entry = Self.entry(for: tabId)

        #expect(tasks.install(entry) == nil)
        #expect(tasks.hasTask(for: tabId))
        entry.task.cancel()
    }

    /// A tab reaching a second execution while the first still holds the handle means the first is
    /// still running, so the caller has to be handed it rather than losing it.
    @Test("Installing over a live entry hands the old one back")
    func installOverLiveEntryReturnsIt() {
        var tasks = TabQueryTasks()
        let tabId = UUID()
        let first = Self.entry(for: tabId)
        let second = Self.entry(for: tabId)

        _ = tasks.install(first)
        let displaced = tasks.install(second)

        #expect(displaced?.owner == first.owner)
        #expect(tasks.hasTask(for: tabId))
        first.task.cancel()
        second.task.cancel()
    }

    /// The whole point of the type: tab B's execution never reaches tab A's handle.
    @Test("Installing on one tab leaves another tab's entry alone")
    func installOnOneTabLeavesTheOtherAlone() {
        var tasks = TabQueryTasks()
        let tabA = UUID()
        let tabB = UUID()
        let entryA = Self.entry(for: tabA)
        let entryB = Self.entry(for: tabB)

        _ = tasks.install(entryA)
        #expect(tasks.install(entryB) == nil)

        #expect(tasks.hasTask(for: tabA))
        #expect(tasks.hasTask(for: tabB))
        entryA.task.cancel()
        entryB.task.cancel()
    }

    @Test("Retiring works only for the owner that installed the entry")
    func retireRequiresTheExactOwner() {
        var tasks = TabQueryTasks()
        let tabId = UUID()
        let entry = Self.entry(for: tabId)
        let stranger = Self.entry(for: tabId)

        _ = tasks.install(entry)

        #expect(tasks.retire(stranger.owner) == false)
        #expect(tasks.hasTask(for: tabId))
        let retired = tasks.retire(entry.owner)
        #expect(retired)
        #expect(tasks.hasTask(for: tabId) == false)
        entry.task.cancel()
        stranger.task.cancel()
    }

    /// Fetch All has no claim of its own, so its owner is a token. Two of them on one tab are still
    /// two owners, and the first finishing must not retire the second.
    @Test("A second Fetch All token on the same tab is a different owner")
    func unclaimedWorkTokensAreDistinctOwners() {
        var tasks = TabQueryTasks()
        let tabId = UUID()
        let first = Self.entry(for: .unclaimedWork(tabId: tabId, token: UUID()))
        let second = Self.entry(for: .unclaimedWork(tabId: tabId, token: UUID()))

        _ = tasks.install(first)
        _ = tasks.install(second)

        #expect(tasks.retire(first.owner) == false)
        let retired = tasks.retire(second.owner)
        #expect(retired)
        first.task.cancel()
        second.task.cancel()
    }

    /// A Stop, a supersede and a tab close all end that tab's work whoever started it.
    @Test("Removing by tab takes the entry whoever installed it")
    func removeByTabIgnoresTheOwner() {
        var tasks = TabQueryTasks()
        let tabId = UUID()
        let entry = Self.entry(for: tabId)

        _ = tasks.install(entry)

        #expect(tasks.remove(tabId: tabId)?.owner == entry.owner)
        #expect(tasks.remove(tabId: tabId) == nil)
        entry.task.cancel()
    }

    @Test("Removing everything hands back every entry so each lease can be cancelled")
    func removeAllReturnsEveryEntry() {
        var tasks = TabQueryTasks()
        let entryA = Self.entry(for: UUID())
        let entryB = Self.entry(for: UUID())
        _ = tasks.install(entryA)
        _ = tasks.install(entryB)

        let removed = tasks.removeAll()

        #expect(Set(removed.map(\.owner)) == Set([entryA.owner, entryB.owner]))
        #expect(tasks.hasTask(for: entryA.owner.tabId) == false)
        #expect(tasks.hasTask(for: entryB.owner.tabId) == false)
        entryA.task.cancel()
        entryB.task.cancel()
    }

    @Test("The awaited handle is the one installed for that tab")
    func taskLookupIsPerTab() async {
        var tasks = TabQueryTasks()
        let tabA = UUID()
        let tabB = UUID()
        let entryA = Self.entry(for: tabA)
        _ = tasks.install(entryA)

        #expect(tasks.task(for: tabA) != nil)
        #expect(tasks.task(for: tabB) == nil)
        await tasks.task(for: tabA)?.value
    }

    /// A cancel names one execution's lease, so two executions must never share one.
    @Test("Each execution gets a lease of its own")
    func leasesAreDistinct() {
        let mine = DriverLeaseOwner()
        let theirs = DriverLeaseOwner()
        let copy = mine
        #expect(mine != theirs)
        #expect(mine == copy)
    }

    private static func entry(for tabId: UUID) -> TabQueryTask {
        entry(for: .claim(TabExecutionClaim(tabId: tabId, epoch: Int.random(in: 1 ... 1_000_000), startedAt: .now)))
    }

    private static func entry(for owner: TabQueryTaskOwner) -> TabQueryTask {
        TabQueryTask(owner: owner, lease: DriverLeaseOwner(), task: Task {})
    }
}
