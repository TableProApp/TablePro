//
//  RedisKeyspacePageTests.swift
//  TableProTests
//

import Foundation
import Testing

struct RedisKeyspacePageTests {
    @Test("A page that stops mid-scan names the cursor to continue from")
    func unfinishedPageNamesNextCursor() throws {
        let page = RedisKeyspacePage(cursor: "17", keys: ["a"], isIncomplete: false)
        let notice = try #require(page.nextCursorNotice)
        #expect(notice.contains("17"))
    }

    @Test("A page that ends the scan has nothing to continue")
    func finishedPageHasNoNotice() {
        let page = RedisKeyspacePage(cursor: RedisClusterCursor.start, keys: ["a"], isIncomplete: false)
        #expect(page.nextCursorNotice == nil)
    }

    @Test("An empty page mid-scan still names the cursor, because later pages can hold keys")
    func emptyUnfinishedPageNamesNextCursor() throws {
        let page = RedisKeyspacePage(cursor: "4096", keys: [], isIncomplete: false)
        let notice = try #require(page.nextCursorNotice)
        #expect(notice.contains("4096"))
    }

    @Test("A cluster cursor is named whole, so it can be passed back to SCAN")
    func clusterCursorIsNamedWhole() throws {
        let cursor = RedisClusterCursor.encode(nodeId: "07c37dfeb235213a872192d90877d0cd55635b91", nodeCursor: "28")
        let page = RedisKeyspacePage(cursor: cursor, keys: ["a"], isIncomplete: false)
        let notice = try #require(page.nextCursorNotice)
        #expect(notice.contains(cursor))
    }

    @Test("A page that stops mid-scan reaches the result as a status message, not as a truncated result")
    func unfinishedPageOutcomeCarriesCursorWithoutTruncating() throws {
        let page = RedisKeyspacePage(cursor: "17", keys: ["a", "b"], isIncomplete: false)
        let outcome = RedisScanPageOutcome(page: page, rowLimit: 5_000_000)
        let message = try #require(outcome.statusMessage)
        #expect(message.contains("17"))
        #expect(outcome.keys == ["a", "b"])
        #expect(!outcome.isTruncated)
    }

    @Test("An empty page mid-scan still reaches the result with its cursor")
    func emptyUnfinishedPageOutcomeCarriesCursor() throws {
        let page = RedisKeyspacePage(cursor: "4096", keys: [], isIncomplete: false)
        let outcome = RedisScanPageOutcome(page: page, rowLimit: 5_000_000)
        let message = try #require(outcome.statusMessage)
        #expect(message.contains("4096"))
        #expect(outcome.keys.isEmpty)
    }

    @Test("A page that ends the scan reaches the result with no status message")
    func finishedPageOutcomeHasNoStatusMessage() {
        let page = RedisKeyspacePage(cursor: RedisClusterCursor.start, keys: ["a"], isIncomplete: false)
        let outcome = RedisScanPageOutcome(page: page, rowLimit: 5_000_000)
        #expect(outcome.statusMessage == nil)
        #expect(!outcome.isTruncated)
    }

    @Test("A page over the row limit is capped and marked truncated")
    func pageOverRowLimitIsCappedAndTruncated() {
        let page = RedisKeyspacePage(cursor: "9", keys: ["a", "b", "c"], isIncomplete: false)
        let outcome = RedisScanPageOutcome(page: page, rowLimit: 2)
        #expect(outcome.keys == ["a", "b"])
        #expect(outcome.isTruncated)
    }

    @Test("A page whose walk restarted a node is marked truncated")
    func incompletePageIsTruncated() {
        let page = RedisKeyspacePage(cursor: RedisClusterCursor.start, keys: ["a"], isIncomplete: true)
        let outcome = RedisScanPageOutcome(page: page, rowLimit: 5_000_000)
        #expect(outcome.isTruncated)
    }
}
