//
//  SidebarNameFilterTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct SidebarNameFilterTests {
    // MARK: - Matching

    @Test("Empty or whitespace query matches everything")
    func emptyQueryMatches() {
        #expect(SidebarNameFilter.matches(query: "", candidate: "users"))
        #expect(SidebarNameFilter.matches(query: "   ", candidate: "users"))
    }

    @Test("Substring in the middle of the name matches")
    func substringMatches() {
        #expect(SidebarNameFilter.matches(query: "ser", candidate: "users"))
        #expect(SidebarNameFilter.matches(query: "log", candidate: "audit_log"))
    }

    @Test("Scattered subsequence no longer matches")
    func subsequenceDoesNotMatch() {
        #expect(!SidebarNameFilter.matches(query: "usr", candidate: "users"))
        #expect(!SidebarNameFilter.matches(query: "ur", candidate: "user"))
        #expect(!SidebarNameFilter.matches(query: "upv", candidate: "user_profile_view"))
        #expect(!SidebarNameFilter.matches(query: "user", candidate: "purchase_events_registry"))
    }

    @Test("Matching is case and diacritic insensitive")
    func caseAndDiacriticInsensitive() {
        #expect(SidebarNameFilter.matches(query: "USER", candidate: "users"))
        #expect(SidebarNameFilter.matches(query: "user", candidate: "USERS"))
        #expect(SidebarNameFilter.matches(query: "cafe", candidate: "café_orders"))
    }

    @Test("Leading and trailing whitespace is trimmed")
    func whitespaceTrimmed() {
        #expect(SidebarNameFilter.tier(query: "  user  ", candidate: "users") == .prefix)
    }

    // MARK: - Tiers

    @Test("Exact match reports the exact tier")
    func exactTier() {
        #expect(SidebarNameFilter.tier(query: "users", candidate: "users") == .exact)
        #expect(SidebarNameFilter.tier(query: "USERS", candidate: "users") == .exact)
    }

    @Test("Prefix match reports the prefix tier")
    func prefixTier() {
        #expect(SidebarNameFilter.tier(query: "user", candidate: "users") == .prefix)
        #expect(SidebarNameFilter.tier(query: "user", candidate: "user_log") == .prefix)
    }

    @Test("Interior substring reports the substring tier")
    func substringTier() {
        #expect(SidebarNameFilter.tier(query: "ser", candidate: "users") == .substring)
        #expect(SidebarNameFilter.tier(query: "log", candidate: "user_log") == .substring)
    }

    @Test("Non-match reports no tier")
    func noTier() {
        #expect(SidebarNameFilter.tier(query: "usr", candidate: "users") == nil)
        #expect(SidebarNameFilter.tier(query: "zzz", candidate: "users") == nil)
    }

    // MARK: - Ranking

    @Test("Empty query keeps the original order")
    func rankedEmptyQueryPreservesOrder() {
        let result = SidebarNameFilter.ranked(["orders", "users"], query: "", name: { $0 })
        #expect(result == ["orders", "users"])
    }

    @Test("Prefix matches sort above interior-substring matches")
    func rankedPrefixBeforeSubstring() {
        let names = ["audit_user", "users", "user_log", "orders"]
        let result = SidebarNameFilter.ranked(names, query: "user", name: { $0 })
        #expect(result == ["users", "user_log", "audit_user"])
    }

    @Test("Exact match sorts above prefix matches")
    func rankedExactBeforePrefix() {
        let names = ["user_log", "user", "users"]
        let result = SidebarNameFilter.ranked(names, query: "user", name: { $0 })
        #expect(result == ["user", "user_log", "users"])
    }

    @Test("Within a tier the original order is stable")
    func rankedStableWithinTier() {
        let names = ["ab_x", "ab_a", "ab_m"]
        let result = SidebarNameFilter.ranked(names, query: "ab", name: { $0 })
        #expect(result == ["ab_x", "ab_a", "ab_m"])
    }
}
