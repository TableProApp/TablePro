//
//  SchemaColumnStoreCancellationTests.swift
//  TableProTests
//
//  The shared fetch is an unstructured task, so it inherits nothing from whoever awaits it.
//  Clicking past a table used to leave its metadata query running to the end, holding the serial
//  metadata connection while every table behind it queued (#2058).
//

import Foundation
@testable import TablePro
import Testing

@Suite("Schema column store cancellation", .serialized)
@MainActor
struct SchemaColumnStoreCancellationTests {
    @Test("Cancelling the only waiter cancels the fetch")
    func soleWaiterCancellationStopsTheFetch() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()

        let waiter = Task { await store.load("users", fetch: probe.fetch) }
        #expect(await Self.wait(until: { probe.startCount == 1 }))

        waiter.cancel()
        await waiter.value

        #expect(probe.cancelCount == 1)
        #expect(probe.finishCount == 0)
    }

    /// Two tabs opening the same table share one fetch. The first one to be clicked past must not
    /// take the result away from the one still waiting for it.
    ///
    /// The cancelled waiter stays suspended until the fetch it shares finishes. Nothing can be
    /// done about that without abandoning the caller mid-load, and it costs nothing: the caller
    /// discards the result the moment it resumes. Releasing the probe is therefore what lets the
    /// cancelled waiter return, not the cancel.
    @Test("A second waiter keeps the fetch alive when the first is cancelled")
    func remainingWaiterKeepsTheFetchAlive() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()

        let first = Task { await store.load("users", fetch: probe.fetch) }
        #expect(await Self.wait(until: { probe.startCount == 1 }))
        let second = Task { await store.load("users", fetch: probe.fetch) }
        #expect(await Self.wait(until: { store.waiterCount(for: "users") == 2 }))

        first.cancel()
        #expect(await Self.wait(until: { store.waiterCount(for: "users") == 1 }))
        #expect(probe.cancelCount == 0)

        probe.release()
        await first.value
        await second.value

        #expect(probe.finishCount == 1)
        #expect(store.cached("users")?.columns == ["id", "name"])
    }

    /// Clicking away from a table and straight back to it. The abandoned fetch is cancelled but
    /// its entry can still be in the map, and adopting it would mean waiting on a fetch that is
    /// never going to produce anything.
    @Test("A caller arriving after a cancel starts a fresh fetch")
    func callerAfterCancellationStartsAFreshFetch() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()

        let abandoned = Task { await store.load("users", fetch: probe.fetch) }
        #expect(await Self.wait(until: { probe.startCount == 1 }))
        abandoned.cancel()
        await abandoned.value

        probe.release()
        await store.load("users", fetch: probe.fetch)

        #expect(probe.startCount == 2)
        #expect(store.cached("users")?.columns == ["id", "name"])
    }

    @Test("Callers for the same key share one fetch")
    func concurrentCallersShareOneFetch() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()

        let first = Task { await store.load("users", fetch: probe.fetch) }
        let second = Task { await store.load("users", fetch: probe.fetch) }
        #expect(await Self.wait(until: { store.waiterCount(for: "users") == 2 }))

        probe.release()
        await first.value
        await second.value

        #expect(probe.startCount == 1)
    }

    @Test("A cached entry is served without fetching again")
    func cachedEntrySkipsTheFetch() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()
        probe.release()

        await store.load("users", fetch: probe.fetch)
        await store.load("users", fetch: probe.fetch)

        #expect(probe.startCount == 1)
        #expect(store.cached("users")?.primaryKeys == ["id"])
    }

    @Test("Clearing the store cancels an in-flight fetch")
    func removeAllCancelsInFlightFetches() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()

        let waiter = Task { await store.load("users", fetch: probe.fetch) }
        #expect(await Self.wait(until: { probe.startCount == 1 }))

        store.removeAll()
        await waiter.value

        #expect(probe.cancelCount == 1)
        #expect(store.cached("users") == nil)
    }

    /// A fetch that fails leaves no entry, so the next caller is free to try again rather than
    /// being served a hole.
    @Test("A failed fetch caches nothing and the next caller retries")
    func failedFetchLetsTheNextCallerRetry() async {
        let store = SchemaColumnStore()
        let probe = FetchProbe()
        probe.release()
        probe.result = nil

        await store.load("users", fetch: probe.fetch)
        #expect(store.cached("users") == nil)

        probe.result = (["id"], ["id"])
        await store.load("users", fetch: probe.fetch)

        #expect(probe.startCount == 2)
        #expect(store.cached("users")?.columns == ["id"])
    }

    /// The defect: a cancelled waiter's cleanup runs on a deferred hop. If its own load finishes
    /// and a new caller takes the key before that hop lands, the hop used to decrement the new
    /// load's waiter count to zero and cancel a fetch nobody had abandoned.
    @Test("A withdrawal aimed at a finished load cannot cancel the one that replaced it")
    func staleWithdrawalCannotCancelTheNextLoad() async {
        let store = SchemaColumnStore()
        let abandonedProbe = FetchProbe()

        let abandoned = Task { await store.load("users", fetch: abandonedProbe.fetch) }
        #expect(await Self.wait(until: { store.loadID(for: "users") != nil }))
        let staleLoadID = store.loadID(for: "users")
        abandoned.cancel()
        await abandoned.value
        #expect(store.loadID(for: "users") == nil)

        let liveProbe = FetchProbe()
        let live = Task { await store.load("users", fetch: liveProbe.fetch) }
        #expect(await Self.wait(until: { liveProbe.startCount == 1 }))
        #expect(store.loadID(for: "users") != staleLoadID)

        if let staleLoadID {
            store.withdrawWaiterForTesting(from: "users", loadID: staleLoadID)
        }

        #expect(liveProbe.cancelCount == 0)

        liveProbe.release()
        await live.value

        #expect(liveProbe.finishCount == 1)
        #expect(store.cached("users")?.columns == ["id", "name"])
    }

    /// A cancelled fetch that finishes late must not overwrite the result of the fetch that
    /// replaced it, so the write is gated on still owning the key.
    @Test("A superseded fetch cannot write its result over a newer one")
    func supersededFetchCannotOverwriteNewerResult() async {
        let store = SchemaColumnStore()
        let stale = FetchProbe()
        stale.result = (["stale"], [])

        let abandoned = Task { await store.load("users", fetch: stale.fetch) }
        #expect(await Self.wait(until: { stale.startCount == 1 }))
        abandoned.cancel()
        await abandoned.value

        let fresh = FetchProbe()
        fresh.release()
        await store.load("users", fetch: fresh.fetch)

        #expect(store.cached("users")?.columns == ["id", "name"])
    }

    private static func wait(
        until condition: () -> Bool,
        within timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

/// Hangs until released or cancelled, so a test can hold a fetch open and decide how it ends.
@MainActor
private final class FetchProbe {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var finishCount = 0
    var result: SchemaColumnStore.Entry? = (["id", "name"], ["id"])

    private var isReleased = false

    func release() {
        isReleased = true
    }

    func fetch() async -> SchemaColumnStore.Entry? {
        startCount += 1
        while !isReleased, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard !Task.isCancelled else {
            cancelCount += 1
            return nil
        }
        finishCount += 1
        return result
    }
}
