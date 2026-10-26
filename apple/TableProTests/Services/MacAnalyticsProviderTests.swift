import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct MacAnalyticsProviderTests {
    private let storage: EphemeralDefaults
    private let provider: MacAnalyticsProvider

    init() throws {
        storage = try EphemeralDefaults()
        provider = MacAnalyticsProvider(defaults: storage.defaults)
    }

    /// A stamp no second mark could write, so a timestamp that survives the mark was not rewritten.
    private func seed(_ key: String) -> Date {
        let recorded = Date(timeIntervalSince1970: 1)
        storage.defaults.set(recorded, forKey: key)
        return recorded
    }

    @Test("Getter returns nil when no timestamp recorded")
    func gettersAreNilByDefault() {
        #expect(provider.connectionAttemptedAt == nil)
        #expect(provider.connectionSucceededAt == nil)
        #expect(provider.firstQueryExecutedAt == nil)
    }

    @Test("markConnectionAttempted writes once and never overwrites")
    func attemptedIsWriteOnce() {
        provider.markConnectionAttempted()
        #expect(provider.connectionAttemptedAt != nil)

        let first = seed(MacAnalyticsProvider.Keys.connectionAttemptedAt)
        provider.markConnectionAttempted()

        #expect(provider.connectionAttemptedAt == first, "Second mark must not overwrite the first timestamp")
    }

    @Test("markConnectionSucceeded writes once and never overwrites")
    func succeededIsWriteOnce() {
        provider.markConnectionSucceeded()
        #expect(provider.connectionSucceededAt != nil)

        let first = seed(MacAnalyticsProvider.Keys.connectionSucceededAt)
        provider.markConnectionSucceeded()

        #expect(provider.connectionSucceededAt == first)
    }

    @Test("markFirstQueryExecuted writes once and never overwrites")
    func firstQueryIsWriteOnce() {
        provider.markFirstQueryExecuted()
        #expect(provider.firstQueryExecutedAt != nil)

        let first = seed(MacAnalyticsProvider.Keys.firstQueryExecutedAt)
        provider.markFirstQueryExecuted()

        #expect(provider.firstQueryExecutedAt == first)
    }

    @Test("markAIChatSent keeps the latest message, overwriting the one before")
    func aiChatSentIsOverwritten() throws {
        #expect(provider.aiChatSentAt == nil)
        let earlier = seed(MacAnalyticsProvider.Keys.aiChatSentAt)

        provider.markAIChatSent()

        let latest = try #require(provider.aiChatSentAt)
        #expect(latest > earlier)
    }

    @Test("Reports each configured provider kind once, sorted, and only while AI is on")
    func aiProviderKinds() {
        var ai = AISettings.default
        ai.providers = [
            AIProviderConfig(name: "Local", type: .ollama),
            AIProviderConfig(name: "Work", type: .claude),
            AIProviderConfig(name: "Laptop", type: .ollama)
        ]
        #expect(MacAnalyticsProvider.aiProviderKinds(ai) == ["claude", "ollama"])

        ai.enabled = false
        #expect(MacAnalyticsProvider.aiProviderKinds(ai) == nil)

        ai.enabled = true
        ai.providers = []
        #expect(MacAnalyticsProvider.aiProviderKinds(ai) == nil)
    }

    @Test("markConnectionAttempted does not affect connectionSucceededAt")
    func attemptedDoesNotAffectSucceeded() {
        provider.markConnectionAttempted()

        #expect(provider.connectionAttemptedAt != nil)
        #expect(provider.connectionSucceededAt == nil)
        #expect(provider.firstQueryExecutedAt == nil)
    }

    @Test("Repeated successful connections keep the timestamp write-once")
    func succeededTimestampStaysWriteOnce() {
        provider.markConnectionSucceeded()
        #expect(provider.connectionSucceededAt != nil)

        let firstSucceededAt = seed(MacAnalyticsProvider.Keys.connectionSucceededAt)
        provider.markConnectionSucceeded()
        provider.markConnectionSucceeded()

        #expect(provider.connectionSucceededAt == firstSucceededAt)
    }
}
