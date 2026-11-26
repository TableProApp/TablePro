import Foundation
@testable import TableProUtilities
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

    @Test("A prepared query trims once and ranks like the text it was made from")
    func preparedQueryRanksLikeText() {
        let query = SidebarNameQuery("  user ")
        let names = ["audit_user", "users", "user", "orders", "user_log"]
        #expect(query.text == "user")
        #expect(query.tier(of: "USERS") == .prefix)
        #expect(SidebarNameFilter.ranked(names, query: query, name: { $0 })
            == SidebarNameFilter.ranked(names, query: "  user ", name: { $0 }))
        #expect(SidebarNameFilter.ranked(names, query: query, name: { $0 }) == ["user", "users", "user_log", "audit_user"])
    }

    @Test("An empty prepared query matches every name as exact")
    func emptyPreparedQuery() {
        let query = SidebarNameQuery("   ")
        #expect(query.isEmpty)
        #expect(query.tier(of: "anything") == .exact)
        #expect(SidebarNameFilter.ranked(["b", "a"], query: query, name: { $0 }) == ["b", "a"])
    }

    // MARK: - Folding

    // What the locale-aware search answered before ASCII names took the byte search, pinned so neither path drifts.
    @Test(
        "A name or query outside ASCII keeps the locale-aware answer",
        arguments: [
            ("strasse", "straße", SidebarNameMatchTier?.some(.exact)),
            ("STRASSE", "Straße", .exact),
            ("straße", "strasse", .exact),
            ("fi", "\u{FB01}le", .prefix),
            ("file", "\u{FB01}le", .exact),
            ("\u{FB01}", "file", .prefix),
            ("i", "İstanbul", .prefix),
            ("istanbul", "İSTANBUL", .exact),
            ("I", "ılık", nil),
            ("cafe", "café", .exact),
            ("café", "CAFE", .exact),
            ("cafe", "cafe\u{301}", .exact),
            ("ae", "æther", nil),
            ("o", "Ørsted", nil),
        ]
    )
    func nonASCIIKeepsLocaleAnswer(query: String, candidate: String, tier: SidebarNameMatchTier?) {
        #expect(SidebarNameQuery(query).tier(of: candidate) == tier)
    }

    @Test("Every ASCII query ranks every ASCII name as the locale-aware search does")
    func asciiMatchesLocaleAwareSearch() {
        let names = [
            "users", "USERS", "User_Log", "audit_user", "a", "A", "orders2024", "order-items", "x.y", "ab ab",
            "~tilde", "^caret", "`tick`", "[bracket]", "{brace}", "back\\slash", "q\"uote", "tab\tname", "e^", "",
        ]
        let queries = ["u", "U", "user", "USER_L", "log", "a", "2024", "-", ".", " ab", "~", "^", "`", "]", "\\", "\"", "e", "zz"]
        for query in queries {
            let prepared = SidebarNameQuery(query)
            for name in names {
                #expect(prepared.tier(of: name) == Self.localeAwareTier(prepared.text, name), "\(query) in \(name)")
            }
        }
    }

    @Test("A locale that folds I to a dotless i sends ASCII names to the locale-aware search")
    func turkishFoldsByLocale() {
        #expect(!AsciiFolding.matchesLocale(Locale(identifier: "tr_TR")))
        #expect(AsciiFolding.matchesLocale(Locale(identifier: "en_US")))
    }

    private static func localeAwareTier(_ query: String, _ candidate: String) -> SidebarNameMatchTier? {
        guard !query.isEmpty else { return .exact }
        let candidateString = candidate as NSString
        let range = candidateString.localizedStandardRange(of: query)
        guard range.location != NSNotFound else { return nil }
        guard range.location == 0 else { return .substring }
        return range.length == candidateString.length ? .exact : .prefix
    }
}
