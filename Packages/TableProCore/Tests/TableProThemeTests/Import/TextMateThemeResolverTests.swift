import Foundation
@testable import TableProTheme
import Testing

struct TextMateThemeResolverTests {
    private static let sqlKeyword = ["source.sql", "keyword.other.DML.sql"]

    private static func resolver(_ rules: [(String, String?)]) throws -> TextMateThemeResolver {
        try TextMateThemeResolver(
            rules: [TextMateRule(scope: .unscoped, foreground: "#EEEEEE")]
                + rules.map { TextMateRule(scope: .selector($0.0), foreground: $0.1) }
        )
    }

    @Test("The deepest dotted prefix wins")
    func deeperScopeWins() throws {
        let resolver = try Self.resolver([("keyword", "#111111"), ("keyword.other", "#222222")])

        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#222222")
        #expect(resolver.foreground(forScopes: ["source.sql", "keyword.operator.sql"]) == "#111111")
    }

    @Test("Of two rules for one scope, the later wins")
    func laterRuleWins() throws {
        let resolver = try Self.resolver([("keyword", "#111111"), ("constant", "#555555"), ("keyword", "#333333")])

        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#333333")
    }

    @Test("A rule with a matching parent scope beats a deeper rule without one at the same node")
    func parentSelectorIsMoreSpecific() throws {
        let resolver = try Self.resolver([
            ("keyword.other", "#111111"),
            ("source.sql keyword.other", "#222222"),
            ("source.js keyword.other", "#333333"),
        ])

        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#222222")
        #expect(resolver.foreground(forScopes: ["source.go", "keyword.other.go"]) == "#111111")
    }

    @Test("Of two matching parents, the longer innermost one is more specific, then the rule with more")
    func parentSpecificityOrder() throws {
        let stack = ["source.sql", "meta.statement.sql", "keyword.other.DML.sql"]
        let byLength = try Self.resolver([("meta keyword", "#AAAAAA"), ("source.sql keyword", "#BBBBBB")])
        let byCount = try Self.resolver([("meta.statement keyword", "#AAAAAA"), ("source.sql meta.statement keyword", "#BBBBBB")])

        #expect(byLength.foreground(forScopes: stack) == "#BBBBBB")
        #expect(byCount.foreground(forScopes: stack) == "#BBBBBB")
    }

    @Test("> requires the direct parent")
    func childCombinator() throws {
        let resolver = try Self.resolver([("keyword", "#111111"), ("source.sql > keyword", "#222222")])

        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#222222")
        #expect(resolver.foreground(forScopes: ["source.sql", "meta.x", "keyword.other"]) == "#111111")
    }

    @Test("- is not an exclusion: the selector parses as parents and never matches")
    func minusIsIgnored() throws {
        let resolver = try Self.resolver([("keyword", "#111111"), ("keyword - keyword.operator", "#666666")])

        #expect(resolver.foreground(forScopes: ["source.sql", "keyword.operator.comparison.sql"]) == "#111111")
        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#111111")
    }

    @Test("A rule that sets no color keeps the parent's")
    func ruleWithoutColorInherits() throws {
        let resolver = try Self.resolver([("keyword", "#111111"), ("keyword.operator", nil), ("keyword.other", "not a color")])

        #expect(resolver.foreground(forScopes: ["source.sql", "keyword.operator.comparison.sql"]) == "#111111")
        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#111111")
    }

    @Test("A selector list splits on commas, trimmed, and an array scope is taken element by element")
    func selectorLists() throws {
        let resolver = try TextMateThemeResolver(rules: [
            TextMateRule(scope: .selector(",string , comment,"), foreground: "#123456"),
            TextMateRule(scope: .selectors(["entity.name.type", "support.type, storage"]), foreground: "#654321"),
        ])

        #expect(resolver.foreground(forScopes: ["source.sql", "string.quoted.single.sql"]) == "#123456")
        #expect(resolver.foreground(forScopes: ["source.sql", "comment.line.sql"]) == "#123456")
        #expect(resolver.foreground(forScopes: ["source.sql", "entity.name.type.sql"]) == "#654321")
        #expect(resolver.foreground(forScopes: ["source.sql", "storage.type.sql"]) == nil)
    }

    @Test("A prefix matches only at a dot")
    func prefixMatchesAtADot() throws {
        let resolver = try Self.resolver([("keyword", "#111111")])

        #expect(resolver.foreground(forScopes: ["source.sql", "keywords.sql"]) == nil)
        #expect(resolver.foreground(forScopes: ["source.sql", "keyword"]) == "#111111")
    }

    @Test("Each scope level merges over the one above, so a root rule colors what nothing deeper does")
    func perLevelMerge() throws {
        let resolver = try Self.resolver([("source.sql", "#999999"), ("string", "#123123")])

        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == "#999999")
        #expect(resolver.foreground(forScopes: ["source.sql", "string.quoted.sql"]) == "#123123")
    }

    @Test("The unscoped rules set the default, and no match leaves the token on it")
    func defaults() throws {
        let resolver = try TextMateThemeResolver(rules: [
            TextMateRule(scope: .unscoped, foreground: "#eeeeee"),
            TextMateRule(scope: .unscoped, foreground: "#dddddd"),
            TextMateRule(scope: .selector("comment"), foreground: "#888888"),
        ])

        #expect(resolver.defaultForeground == "#DDDDDD")
        #expect(resolver.foreground(forScopes: Self.sqlKeyword) == nil)
    }

    @Test("Rules past the cap, counted after selectors split, are refused")
    func ruleCap() throws {
        let fits = (0 ..< TextMateThemeResolver.maximumRuleCount).map { "scope.n\($0)" }

        #expect(throws: Never.self) {
            try TextMateThemeResolver(rules: [TextMateRule(scope: .selectors(fits), foreground: "#111111")])
        }
        #expect(throws: ThemeLoadError.tooManyTokenRules(limit: TextMateThemeResolver.maximumRuleCount)) {
            try TextMateThemeResolver(rules: [TextMateRule(scope: .selectors(fits + ["one.more"]), foreground: "#111111")])
        }
    }

    @Test("A selector is capped in length after commas split it and whitespace is trimmed")
    func selectorLengthCap() throws {
        let limit = TextMateThemeResolver.maximumSelectorLength
        let fits = String(repeating: "a", count: limit)
        let over = String(repeating: "a", count: limit + 1)

        #expect(throws: Never.self) { try Self.resolver([("  \(fits)  ,\(fits)", "#111111")]) }
        #expect(throws: ThemeLoadError.tokenScopeTooLong(limit: limit)) { try Self.resolver([("keyword, \(over)", "#111111")]) }
        #expect(throws: ThemeLoadError.tokenScopeTooLong(limit: limit)) {
            try TextMateThemeResolver(rules: [TextMateRule(scope: .selectors(["keyword", over]), foreground: "#111111")])
        }
    }

    @Test("Every scope in a selector, parents too, has at most 32 dot-separated parts")
    func scopePartCap() throws {
        let limit = TextMateThemeResolver.maximumScopeParts
        let fits = Array(repeating: "a", count: limit).joined(separator: ".")
        let over = fits + ".a"

        #expect(throws: Never.self) { try Self.resolver([("\(fits) \(fits)", "#111111")]) }
        #expect(throws: ThemeLoadError.tokenScopeHasTooManyParts(limit: limit)) { try Self.resolver([(over, "#111111")]) }
        #expect(throws: ThemeLoadError.tokenScopeHasTooManyParts(limit: limit)) { try Self.resolver([("\(over) keyword", "#111111")]) }
        #expect(throws: ThemeLoadError.tokenScopeHasTooManyParts(limit: limit)) { try Self.resolver([(String(repeating: ".", count: limit), "#111111")]) }
    }

    @Test("The deepest scope the cap allows resolves to its own rule")
    func deepestScopeResolves() throws {
        let scope = Array(repeating: "a", count: TextMateThemeResolver.maximumScopeParts).joined(separator: ".")
        let resolver = try Self.resolver([("a", "#111111"), (scope, "#222222")])

        #expect(resolver.foreground(forScopes: [scope + ".sql"]) == "#222222")
        #expect(resolver.foreground(forScopes: ["a.b"]) == "#111111")
    }

    @Test("A rule that lands on a child changes the child's copy of a parent-scoped rule, never the parent's")
    func childRulesStayOnTheChild() throws {
        let resolver = try Self.resolver([
            ("source.sql keyword", "#111111"),
            ("source.sql keyword.other", "#222222"),
            ("meta.block keyword.other", "#333333"),
        ])

        #expect(resolver.foreground(forScopes: ["source.sql", "keyword.control.sql"]) == "#111111")
        #expect(resolver.foreground(forScopes: ["source.sql", "keyword.other.sql"]) == "#222222")
        #expect(resolver.foreground(forScopes: ["meta.block", "keyword.other.sql"]) == "#333333")
        #expect(resolver.foreground(forScopes: ["meta.block", "keyword.control.sql"]) == nil)
    }
}
