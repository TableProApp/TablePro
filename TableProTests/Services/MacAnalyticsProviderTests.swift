//
//  MacAnalyticsProviderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("MacAnalyticsProvider write-once timestamp semantics")
struct MacAnalyticsProviderTests {
    private static let suiteCounter = SuiteCounter()

    private final class SuiteCounter: @unchecked Sendable {
        private var value: Int = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func makeProvider(test: String = #function) throws -> (MacAnalyticsProvider, UserDefaults) {
        let id = "test.MacAnalyticsProviderTests.\(test).\(Self.suiteCounter.next()).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: id))
        defaults.removePersistentDomain(forName: id)
        return (MacAnalyticsProvider(defaults: defaults), defaults)
    }

    @Test("Getter returns nil when no timestamp recorded")
    func gettersAreNilByDefault() throws {
        let (provider, _) = try makeProvider()
        #expect(provider.connectionAttemptedAt == nil)
        #expect(provider.connectionSucceededAt == nil)
        #expect(provider.firstQueryExecutedAt == nil)
    }

    @Test("markConnectionAttempted writes once and never overwrites")
    func attemptedIsWriteOnce() throws {
        let (provider, _) = try makeProvider()
        provider.markConnectionAttempted()
        let first = provider.connectionAttemptedAt
        #expect(first != nil)

        Thread.sleep(forTimeInterval: 0.01)
        provider.markConnectionAttempted()
        let second = provider.connectionAttemptedAt

        #expect(first == second, "Second mark must not overwrite the first timestamp")
    }

    @Test("markConnectionSucceeded writes once and never overwrites")
    func succeededIsWriteOnce() throws {
        let (provider, _) = try makeProvider()
        provider.markConnectionSucceeded()
        let first = provider.connectionSucceededAt
        #expect(first != nil)

        Thread.sleep(forTimeInterval: 0.01)
        provider.markConnectionSucceeded()
        let second = provider.connectionSucceededAt

        #expect(first == second)
    }

    @Test("markFirstQueryExecuted writes once and never overwrites")
    func firstQueryIsWriteOnce() throws {
        let (provider, _) = try makeProvider()
        provider.markFirstQueryExecuted()
        let first = provider.firstQueryExecutedAt
        #expect(first != nil)

        Thread.sleep(forTimeInterval: 0.01)
        provider.markFirstQueryExecuted()
        let second = provider.firstQueryExecutedAt

        #expect(first == second)
    }

    @Test("markConnectionAttempted does not affect connectionSucceededAt")
    func attemptedDoesNotAffectSucceeded() throws {
        let (provider, _) = try makeProvider()
        provider.markConnectionAttempted()

        #expect(provider.connectionAttemptedAt != nil)
        #expect(provider.connectionSucceededAt == nil)
        #expect(provider.firstQueryExecutedAt == nil)
    }

    @Test("Repeated successful connections keep the timestamp write-once")
    func succeededTimestampStaysWriteOnce() throws {
        let (provider, _) = try makeProvider()

        provider.markConnectionSucceeded()
        let firstSucceededAt = provider.connectionSucceededAt
        #expect(firstSucceededAt != nil)

        provider.markConnectionSucceeded()
        provider.markConnectionSucceeded()

        #expect(provider.connectionSucceededAt == firstSucceededAt)
    }
}
